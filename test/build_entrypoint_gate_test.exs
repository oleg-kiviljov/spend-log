defmodule BuildEntrypointGateTest do
  @moduledoc """
  The coverage gate inside `bin/entrypoint-build.sh`, tested directly.

  ## Why this file is here and not in the orchestrator

  The gate's two sides live in different repositories: the orchestrator defines the env var names,
  the control-line shape and the id vocabulary, and THIS repo owns the script that implements them.
  The plan that specified this gate recorded it as *"the first validator with no test, because the
  extract-the-shipped-function technique cannot reach across a repo boundary"* — true of a test
  written over there, and it stops being true the moment the test is written **here**, beside the
  script, where `mix precommit` and CI already run.

  It is deliberately app-neutral (no `SpendLog` in the module name or body), so the
  scaffold rename leaves it alone: every created repo inherits `bin/entrypoint-build.sh` into its own
  builder image, and inherits this check on it with no edit.

  ## The technique

  `validate_coverage()` is **extracted verbatim from the shipped script** and executed, rather than
  restated here. A restatement would pass forever while the shipped function rotted — and this
  function is reachable only inside a container, only via a paid agent run, which makes it the least
  observable code on the build path.

  ## What is worth pinning, and it is not the obvious half

  Rejecting a fabricated id is easy to get right. The cases below that earn their place are the ones
  where being *correct* is subtle:

    * the final line of a file with **no trailing newline** — `wc -l` undercounts it, and using it
      would reject a proof that is exactly right;
    * a note containing a newline, which must not forge a field boundary and report a fault in the
      entry beside the real one;
    * `a..b.ex`, a legal filename that a naive `..` check rejects as path traversal;
    * a criterion the claim simply omitted, which no single entry can detect.
  """
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../bin/entrypoint-build.sh", __DIR__)

  # Twelve-hex ids, the shape `Invoker.Judgment.Criteria.id/1` produces. Their VALUES are irrelevant
  # to the gate by design: it does set membership against the injected list and no hashing at all, so
  # a test that computed them would be testing a rule the script must never implement.
  @ids ["0b88f08eeaf1", "1c99a19ffb02", "2daab2a00c13"]

  setup_all do
    unless System.find_executable("jq") do
      raise "these tests need `jq` — the same dependency entrypoint-build.sh has in the builder image"
    end

    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "build-gate-#{System.unique_integer([:positive])}")

    # A file OUTSIDE the checkout, so `../` traversal has a real target to reach.
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "outside.txt"), "one\ntwo\nthree\n")

    checkout = Path.join(dir, "app")
    File.mkdir_p!(Path.join(checkout, "test"))

    # 12 lines, trailing newline.
    File.write!(
      Path.join(checkout, "test/auth_test.exs"),
      Enum.map_join(1..12, "\n", &"  # line #{&1}") <> "\n"
    )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, checkout: checkout, dir: dir}
  end

  # Pull `validate_coverage()` verbatim out of the shipped entrypoint, define it in a bare shell with
  # the checkout as the working directory (which is where the real script runs it), and execute it.
  # `{:ok, output}` when the gate passes, `{:error, output}` when it rejects.
  #
  # `CRITERION_IDS` is newline-separated ids — exactly what the script derives from
  # `ACCEPTANCE_CRITERIA_IDS_B64` with `cut -f1`.
  defp gate(checkout, entries, opts \\ []) do
    out = Path.join(checkout, "..") |> Path.join("coverage.json") |> Path.expand()
    ids = Keyword.get(opts, :ids, @ids)

    case entries do
      :missing -> File.rm_rf(out)
      raw when is_binary(raw) -> File.write!(out, raw)
      list -> File.write!(out, Jason.encode!(list))
    end

    script = """
    set -uo pipefail
    cd #{checkout}
    COVERAGE_JSON=#{out}
    CRITERION_IDS=$'#{Enum.join(ids, "\\n")}'
    eval "$(awk '/^validate_coverage\\(\\) \\{/,/^\\}$/' #{@entrypoint})"
    validate_coverage
    """

    case System.cmd("bash", ["-c", script], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  end

  defp entry(id, extra \\ %{}) do
    Map.merge(
      %{
        "criterion_id" => id,
        "coverage" => "covered",
        "proof" => "test/auth_test.exs:7",
        "note" => ""
      },
      extra
    )
  end

  # A complete, valid claim — one entry per injected id.
  defp complete(overrides \\ %{}) do
    Enum.map(@ids, fn id -> entry(id, Map.get(overrides, id, %{})) end)
  end

  describe "the happy path" do
    test "a complete claim with resolving proofs passes", %{checkout: checkout} do
      assert {:ok, _} = gate(checkout, complete())
    end

    test "every state is accepted when its own field is supplied", %{checkout: checkout} do
      claim = [
        entry(Enum.at(@ids, 0), %{"coverage" => "covered", "proof" => "test/auth_test.exs"}),
        entry(Enum.at(@ids, 1), %{
          "coverage" => "partial",
          "proof" => "",
          "note" => "the refresh path is untested"
        }),
        entry(Enum.at(@ids, 2), %{
          "coverage" => "not_covered",
          "proof" => "",
          "note" => "ran out of budget"
        })
      ]

      assert {:ok, _} = gate(checkout, claim)
    end

    test "an assignment with no criteria has nothing to validate", %{checkout: checkout} do
      # The real script skips the gate entirely in this case and emits an empty control line; the
      # function itself must still be well-behaved, because "no criteria" must never read as an error.
      assert {:ok, _} = gate(checkout, [], ids: [])
    end
  end

  describe "the id — set membership against the injected list" do
    test "an invented id is rejected", %{checkout: checkout} do
      claim = complete() ++ [entry("deadbeef0000")]
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "deadbeef0000"
      assert out =~ "not one of this assignment's criteria"
    end

    test "a PREFIX of a real id is not a member", %{checkout: checkout} do
      # `grep -Fxq` is whole-line and fixed-string, so this cannot pass. The idiom both finding gates
      # once used — `case " a b c " in *" $x "*)` — admitted any run of adjacent whitelist words, and
      # the equivalent hole here would accept a fabricated id containing a real one.
      claim = complete() ++ [entry(String.slice(hd(@ids), 0, 8))]
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "not one of this assignment's criteria"
    end

    test "a regex metacharacter in the id cannot match anything", %{checkout: checkout} do
      claim = complete() ++ [entry(".*")]
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "not one of this assignment's criteria"
    end

    test "an empty id is rejected before membership is even asked", %{checkout: checkout} do
      claim = complete() ++ [entry("   ")]
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "criterion_id is required"
    end

    test "one criterion claimed twice is rejected", %{checkout: checkout} do
      claim =
        complete() ++ [entry(hd(@ids), %{"coverage" => "not_covered", "note" => "actually no"})]

      assert {:error, out} = gate(checkout, claim)
      assert out =~ "claimed twice"
    end
  end

  describe "completeness — the half no single entry can enforce" do
    test "a criterion with no entry is named", %{checkout: checkout} do
      claim = Enum.map(Enum.take(@ids, 2), &entry/1)
      assert {:error, out} = gate(checkout, claim)
      assert out =~ Enum.at(@ids, 2)
      assert out =~ "has no entry"
    end

    test "an empty array fails rather than passing as a clean report", %{checkout: checkout} do
      # The shape this whole artifact exists to remove. `[]` is well-formed JSON and says nothing, and
      # a gate that accepted it would let a build that reported on no criterion look like one that
      # reported on all of them.
      assert {:error, out} = gate(checkout, [])
      assert out =~ "has no entry"
    end

    test "a claim of the right SIZE made of the wrong ids is still incomplete", %{
      checkout: checkout
    } do
      claim = Enum.map(["deadbeef0000", "0000deadbeef", "beef0000dead"], &entry/1)
      assert {:error, out} = gate(checkout, claim)
      # Both halves fire: three invented ids AND three unanswered criteria. Complete by counting,
      # empty by membership — the two questions are independent, and only asking both catches this.
      assert out =~ "not one of this assignment's criteria"
      assert out =~ "has no entry"
    end
  end

  describe "the state — a closed enum, matched on the value" do
    test "an unrecognised state is rejected", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"coverage" => "mostly done"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "must be covered, partial or not_covered"
    end

    test "`unknown` is refused — it is the orchestrator's marker, not the agent's", %{
      checkout: checkout
    } do
      # The one state whose entire meaning is "the agent did not answer". Accepting it here would let
      # a build file the did-not-report state as though it were a considered answer.
      claim = complete(%{hd(@ids) => %{"coverage" => "unknown"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "must be covered, partial or not_covered"
    end

    test "two whitelist words are not one value — the substring hole, closed", %{
      checkout: checkout
    } do
      claim = complete(%{hd(@ids) => %{"coverage" => "covered partial"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "must be covered, partial or not_covered"
    end

    test "partial and not_covered require a note", %{checkout: checkout} do
      for state <- ["partial", "not_covered"] do
        claim = complete(%{hd(@ids) => %{"coverage" => state, "proof" => "", "note" => "  "}})
        assert {:error, out} = gate(checkout, claim)
        assert out =~ "requires a note"
      end
    end

    test "covered requires a proof", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => ""}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "covered requires a proof"
    end
  end

  describe "the proof — a path that resolves in this checkout" do
    test "a path with no line is accepted", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => "test/auth_test.exs"}})
      assert {:ok, _} = gate(checkout, claim)
    end

    test "a path that does not exist is rejected", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => "test/nope_test.exs:1"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "does not resolve"
    end

    test "an absolute container path is rejected with its own message", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => "/workspace/app/test/auth_test.exs:1"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "absolute container path"
    end

    test "a `..` escape is rejected even though the target exists", %{checkout: checkout} do
      # The file IS there — that is the point. Existence is not membership, and a proof reaching
      # outside the checkout is a claim about something this build did not produce.
      claim = complete(%{hd(@ids) => %{"proof" => "../outside.txt:1"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "escapes the repository"
    end

    test "a filename containing `..` is NOT traversal", %{checkout: checkout} do
      # `a..b.ex` is a legal filename. A substring check on `..` rejects it, and the failure would be
      # a correct proof refused with a security-flavoured message nobody would question.
      File.write!(Path.join(checkout, "test/a..b_test.exs"), "one\n")
      claim = complete(%{hd(@ids) => %{"proof" => "test/a..b_test.exs:1"}})
      assert {:ok, _} = gate(checkout, claim)
    end

    test "a tracked path containing a space resolves", %{checkout: checkout} do
      File.write!(Path.join(checkout, "test/two words_test.exs"), "one\ntwo\n")
      claim = complete(%{hd(@ids) => %{"proof" => "test/two words_test.exs:2"}})
      assert {:ok, _} = gate(checkout, claim)
    end

    test "a line past the end of the file is rejected", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => "test/auth_test.exs:99"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "past the end"
    end

    test "the FINAL line of a file with no trailing newline is accepted", %{checkout: checkout} do
      # `wc -l` counts newlines, so it reports 2 for a 3-line file that does not end in one — and the
      # gate would reject a citation of the last line of exactly the kind of file an agent writes.
      # `awk END{print NR}` counts records. This is the subtle-correctness case, not the obvious one.
      File.write!(Path.join(checkout, "test/no_newline_test.exs"), "one\ntwo\nthree")
      claim = complete(%{hd(@ids) => %{"proof" => "test/no_newline_test.exs:3"}})
      assert {:ok, _} = gate(checkout, claim)
    end

    test "a non-numeric line is rejected", %{checkout: checkout} do
      claim = complete(%{hd(@ids) => %{"proof" => "test/auth_test.exs:seven"}})
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "must be a positive integer"
    end

    test "a proof on a PARTIAL claim is validated too", %{checkout: checkout} do
      # Checking proofs only on `covered` would leave the field a reader trusts unchecked everywhere
      # else. A wrong proof is a wrong proof.
      claim =
        complete(%{
          hd(@ids) => %{
            "coverage" => "partial",
            "note" => "half of it",
            "proof" => "test/nope_test.exs"
          }
        })

      assert {:error, out} = gate(checkout, claim)
      assert out =~ "does not resolve"
    end
  end

  describe "the file itself" do
    test "a missing file is a failure, never an empty report", %{checkout: checkout} do
      assert {:error, out} = gate(checkout, :missing)
      assert out =~ "no coverage file was written"
    end

    test "a non-array is a failure", %{checkout: checkout} do
      assert {:error, out} = gate(checkout, ~s({"criterion_id":"x"}))
      assert out =~ "is not a JSON array"
    end

    test "unparseable JSON is a failure", %{checkout: checkout} do
      assert {:error, out} = gate(checkout, "not json at all")
      assert out =~ "is not a JSON array"
    end

    test "a non-object entry is named by its index", %{checkout: checkout} do
      claim = complete() ++ ["a string"]
      assert {:error, out} = gate(checkout, claim)
      assert out =~ "entry 3: not a JSON object"
    end
  end

  describe "field extraction cannot be forged" do
    # **Measured, and the measurement corrected the comment that was here first.** Two guards look
    # like they carry this block: `gsub("[[:cntrl:]]"; " ")` in the extraction, and the
    # `[ -z "$kind" ] && continue` that skips a blank record. Removing the STRIP alone fails nothing;
    # removing the blank-record GUARD alone fails one of these; removing both fails two.
    #
    # The reason is structural: `note` is the LAST field in the join, and it is the only one an agent
    # writes at length. A newline in it appends lines that carry no delimiter, which the blank-record
    # guard already absorbs — so the strip is belt-and-braces for exactly the field most likely to
    # contain one.
    #
    # The strip stays, and not as decoration: it is what keeps a control character in an EARLIER
    # field (`criterion_id`, `coverage`, `proof`) from shifting every value after it and producing an
    # error message naming the wrong field. The agent gets ONE re-prompt, so an error that misdirects
    # it is close to no error at all. That property is not pinned below, because a space substituted
    # into any of those three fields invalidates them anyway — there is no case where the strip alone
    # changes the verdict. Recorded rather than dressed up as coverage.
    test "a newline inside a note does not shift the fields after it", %{checkout: checkout} do
      claim =
        complete(%{
          hd(@ids) => %{
            "coverage" => "partial",
            "proof" => "",
            "note" => "line one\nline two\nline three"
          }
        })

      assert {:ok, _} = gate(checkout, claim)
    end

    test "a tab inside a note does not split a field", %{checkout: checkout} do
      # The delimiter is US (0x1f) and not a tab for exactly this reason: tab is an IFS *whitespace*
      # character, so bash collapses runs of them and drops leading ones. This pins the OUTCOME (a
      # note with tabs does not fail the gate) rather than the mechanism — switching the delimiter to
      # a tab is what would break it, and no mutation of the two guards above does.
      claim =
        complete(%{
          hd(@ids) => %{"coverage" => "not_covered", "proof" => "", "note" => "a\tb\tc"}
        })

      assert {:ok, _} = gate(checkout, claim)
    end

    test "a US byte inside a value cannot forge a boundary", %{checkout: checkout} do
      # 0x1f is a control character, so the extraction removes it before it can be read back as the
      # separator. Also an outcome test: in the last field `read` would fold a surplus US and its
      # remainder into `note` anyway, so this passes with the strip removed too.
      claim =
        complete(%{
          hd(@ids) => %{
            "coverage" => "partial",
            "proof" => "",
            "note" => "before\u001fafter"
          }
        })

      assert {:ok, _} = gate(checkout, claim)
    end

    test "every error is reported, not just the first", %{checkout: checkout} do
      # A here-string and not a pipe: a piped `while` runs in a subshell, every `errs` increment is
      # discarded at the loop's end, and the gate passes everything while printing all its complaints.
      # One re-prompt is all the agent gets, so it has to see the whole list.
      claim = [
        entry(Enum.at(@ids, 0), %{"coverage" => "nonsense"}),
        entry(Enum.at(@ids, 1), %{"proof" => "test/nope_test.exs"}),
        entry(Enum.at(@ids, 2), %{"proof" => "/absolute.exs"})
      ]

      assert {:error, out} = gate(checkout, claim)
      assert out =~ "must be covered, partial or not_covered"
      assert out =~ "does not resolve"
      assert out =~ "absolute container path"
    end
  end
end

# INSTRUCTIONS — How to Learn With This Repo

This repository is a **guided, build-it-yourself course** for the **dbt Analytics Engineering certification**, wrapped around a real end-to-end analytics project: Olist e-commerce data flowing Kaggle → Google Cloud Storage (data lake) → BigQuery (warehouse) → **dbt** (the heart of it) → a Dash dashboard on Cloud Run, with GitHub Actions CI/CD.

It is **not** a copy-paste tutorial. The point is that *you* build each piece, so that by the end you can not only run the pipeline but explain and defend every dbt concept the exam tests.

---

## The Learning Loop

Work through the project one step at a time, repeating this cycle. An AI assistant (e.g. Claude Code) plays the "coach" role, but the loop works solo too (see [Doing it solo](#doing-it-solo)).

```
1. HINT    → The coach reads PROJECT.md and points you at the next step
             (what to build, which cert topics it covers). No finished code.
2. BUILD   → You build it — solo, or pairing with the coach when stuck.
             TUTORIAL.md is your reference for how-tos and troubleshooting.
3. QUIZ    → Once you've built it, the coach quizzes you on TWO things:
             (a) what you just built and why it works the way it does, and
             (b) the certification topics that step exercises.
4. COMMIT  → Land the work through a pull request (feature branch → PR → merge).
5. REPEAT  → Back to step 1 for the next step.
```

The **quiz step is the reason this works.** Building alone teaches you the tools; being asked "why did you dedupe reviews in staging and not at the source?" or "what does `--defer` resolve `ref()` to?" is what turns hands-on work into exam-ready understanding.

### Ground rules

- **You write the code.** The coach gives hints, reviews what you wrote, and helps when you're genuinely stuck — it does not hand you finished models to paste. When it does provide a snippet (config, boilerplate), you should understand every line before committing it.
- **Get stuck on purpose.** Some failures in this project are *designed* (a source test that must fail, a mid-DAG break to recover from). Sit with an error before asking for the answer — reading dbt's error output is itself a graded exam skill.
- **Explain it back.** If you can't say out loud why something works, you haven't learned it yet. That's what the quiz catches.
- **Commit through PRs.** Every step lands via a feature branch and pull request into a protected `main` — this builds the git + CI muscle the exam and real jobs assume.

---

## The Four Documents

| File | Role in the loop |
|---|---|
| **[PROJECT.md](PROJECT.md)** | The roadmap & requirements. Phases 0–7, each with objectives, acceptance criteria, and the cert topics it covers. The coach hints from here; you check off acceptance criteria as you go. Ends with a **certification traceability matrix** mapping every study-guide topic to the step that practices it. |
| **[TUTORIAL.md](TUTORIAL.md)** | The "when you're stuck" reference. Exact commands, code skeletons, cheat sheets (materializations, node selection, state/defer, tests), and troubleshooting organized by symptom. Reach for it during BUILD; don't read it front-to-back. |
| **[dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md)** | The official exam study guide in searchable form — topic outline, logistics, and 10 worked sample questions. The source of truth for QUIZ topics. |
| **INSTRUCTIONS.md** (this file) | The method — how the loop works and how the docs fit together. |

---

## Using the Loop With an AI Coach

Start a session by pointing the coach at where you are. A prompt like:

> "Resume the project. Check git and the dbt project to see where I left off, hint me on the next step from PROJECT.md, and let me build it. When I'm done, quiz me on what I built and the related certification topics."

The coach should then:
1. Inspect the repo state (git branch/status, which models/tests exist) rather than assume.
2. Give the next step as a **hint + the cert topics it covers**, not a solution.
3. Let you build, offering help only when asked or when you're stuck.
4. **Quiz** you afterward — on your implementation choices *and* the exam topics — and correct misunderstandings.
5. Help you commit via a PR, then move to the next step.

---

## Doing It Solo

No AI coach? The loop still works:
1. **HINT** — read the next step in [PROJECT.md](PROJECT.md).
2. **BUILD** — implement it; use [TUTORIAL.md](TUTORIAL.md) when stuck.
3. **QUIZ** — self-test against the matching topic in [dbt_Study_Guide_AI_Knowledge_Base.md](dbt_Study_Guide_AI_Knowledge_Base.md) and its sample questions. For each thing you built, write one sentence explaining *why*. If you can't, revisit it.
4. **COMMIT** — PR into a protected `main`.

Track coverage with the traceability matrix at the end of PROJECT.md — every row checked and explainable = exam-ready.

---

## The Stack

Cloud Run job (ingestion) · Google Cloud Storage (data lake) · BigQuery (warehouse) · dbt Core (transformation — the emphasis) · Dash on Cloud Run (dashboard) · GitHub Actions (CI/CD) · dbt platform free tier (Phase 7, for Cloud-only exam topics).

---

## Origin

This repo began from a one-page brief: build a full end-to-end analytics project on the Olist dataset with the strongest emphasis on dbt, covering every topic in the dbt Analytics Engineering certification study guide, and produce two documents — `PROJECT.md` (requirements) and `TUTORIAL.md` (a helper for when stuck). Those documents were generated first; this file was added later to capture the build-and-quiz *method* once it proved effective — and to let others learn from the repo the same way.

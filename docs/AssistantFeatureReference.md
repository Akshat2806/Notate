# Notate AI Assistant — removed feature reference

The in-note assistant ("Notate AI") has been removed from the code base. This
document records what it did and how it appeared in the UI, so it can be
re-designed or re-implemented later without recovering the old sources (they
remain in git history before the removal commit).

## Purpose

An on-device, privacy-preserving "think with your notes" chat panel inside the
canvas editor. It answered questions about, summarised, and searched the user's
handwritten/typed notes, imported PDFs and images. All processing was local
(Apple `FoundationModels` on-device language model, Vision OCR, NaturalLanguage);
chat history was session-local and never persisted.

## Where it appeared in the UI

- **Launcher button** in the editor's top chrome (trailing side), showing the
  Notate identity mark (a small multi-colour glyph). Accessibility label:
  "Open Notate" / "Close Notate".
- **Panel presentation**
  - Regular width (iPad full-screen / wide split): a trailing **side rail**
    that shrinks the canvas; the editor chrome reserved extra trailing space.
  - Compact width (Slide Over / narrow multitasking): a **sheet**.
- **Header:** identity mark, the title "Notate" with a violet "AI" capsule badge,
  a **scope menu** pill and a close (✕) button.
- **Scope menu** (`AssistantScope`): *This Page*, *This Notebook* (`item`),
  *Library* (all notebooks).
- **Empty state:** headline "Think with your notes", subtitle "Start with this
  page, or follow an idea across your notebook.", and two suggestion rows that
  fill the composer: "Distill this note" and "Find a thread in my notebook".
- **Conversation:** user messages as right-aligned bubbles; assistant replies as
  streamed markdown with a smooth glyph-by-glyph reveal, a badge for
  summary/preliminary results, in-progress phase labels (VoiceOver announced),
  a Stop control and Retry on failure.
- **Reply actions:** Copy, and **Insert** (adds the answer as a text box on the
  current page via a programmatic canvas insertion).
- **Source references:** each answer listed expandable source rows (page/notebook
  with page number); tapping one **navigated the editor/library to that page
  region** (`navigateToAssistantSource`), opening another notebook if needed.
- **Follow-up suggestions** after an answer.
- **Composer:** text field "Ask or find in your notes" with a Send button.

## Behaviour

- **Task routing** (lexical, local): prompts routed to `summarize`, `answer`,
  `explain`, `study` (flash cards / quiz style help) or `find` (locate passages).
- **Retrieval** (`NotebookIndex`): a local actor indexing PaperKit text,
  PDF text, image content (OCR/classification) and metadata per page, with
  per-page generations, incremental updates from verified canvas checkpoints,
  background library preparation, and recovery markers when thumbnails/derived
  data were stale. Used lexical + semantic scoring and returned bounded source
  sets.
- **Generation:** on-device model with availability checks, prewarming, context
  budgeting/token counting, timeouts, streaming partial results, optional
  "general knowledge" answers when no sources applied.
- **Artifact cache:** reproducible, note-derived summaries cached on disk under
  `AssistantArtifacts/`, invalidated by content hashes and purged on permanent
  deletion of an item.
- **Image enrichment:** drawings/images in notes were described locally so they
  could be searched and cited.
- **Editor integration:** the editor ensured a verified checkpoint was durable
  before each request (`prepareForAssistantRequest`), published index deltas
  after saves, and cancelled/suspended assistant work when the app backgrounded
  or a document surface became interactive.
- **Test hooks:** a deterministic mock model client for UI tests
  (`NOTATE_UI_TEST_REAL_MODEL`, `NOTATE_UI_TEST_ASSISTANT_DELAY`).

## Design tokens that belonged to it

Accent spectrum `assistantCyan / Blue / Violet / Pink / Coral / Amber` in
`NotateDesign.Palette` and the `NotateAssistantIdentityMark` glyph.

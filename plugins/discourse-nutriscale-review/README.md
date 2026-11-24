# NutriScale review integration

This plugin retains the author-facing feedback from Request Revision on the native
ReviewableQueuedPost payload. The existing staff-only review JSON includes:

- nutriscale_review_feedback: the entered feedback, then the selected/custom reason
  when feedback is empty; ordinary Reject Post does not invent a reason.
- nutriscale_can_resubmit: whether this rejected new topic has no replacement.
- nutriscale_replacement_reviewable_id or nutriscale_replacement_topic_id: the
  successful replacement, so the old rejected card is no longer listed as current.

POST /posts.json accepts nutriscale_reviewable_id for the original author only.
The original must be a rejected new topic with no replacement. Its row is locked
while the ordinary NewPostManager validates and creates/queues the revised topic.
A refused write keeps the original editable; a successful write records the link
in the same database transaction. Normal posts and replies use their existing flow.
No new site setting, table, core file, or outbound webhook is required.

NutriScale must use a server-side account allowed to read /review.json and
/review/:id.json. It must enforce target_created_by_id ownership and return only
public-to-author fields, never staff notes, scores, or internal moderation data.
Install this plugin before deploying the NutriScale resubmission adapter. The
adapter exposes editing only when nutriscale_can_resubmit is present and true.
Existing rejected records retain their original content, but past feedback sent
only by private message cannot be recovered by this plugin.

Tests: LOAD_PLUGINS=1 bin/rspec plugins/discourse-nutriscale-review/spec
Lint: bin/lint --fix plugins/discourse-nutriscale-review

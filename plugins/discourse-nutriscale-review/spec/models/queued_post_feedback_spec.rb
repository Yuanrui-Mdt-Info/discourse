# frozen_string_literal: true

RSpec.describe ReviewableQueuedPost do
  fab!(:admin)
  fab!(:author, :user)

  describe "#perform" do
    it "persists Request Revision feedback without changing the native rejection outcome" do
      reviewable = Fabricate(:reviewable_queued_post_topic, target_created_by: author)
      result = reviewable.perform(
        admin,
        :revise_and_reject_post,
        revise_reason: "Needs more detail",
        revise_feedback: "Please describe the recipe ingredients.",
      )

      expect(result.success?).to eq(true)
      expect(reviewable.reload).to be_rejected
      json = ReviewableQueuedPostSerializer.new(reviewable, scope: admin.guardian, root: false).as_json
      expect(json[:nutriscale_review_feedback]).to eq("Please describe the recipe ingredients.")
      expect(json[:nutriscale_can_resubmit]).to eq(true)
      expect(reviewable.payload["raw"]).to be_present
    end

    it "uses a selected reason when feedback is empty" do
      reviewable = Fabricate(:reviewable_queued_post_topic, target_created_by: author)
      reviewable.perform(admin, :revise_and_reject_post, revise_reason: "Off topic")

      expect(reviewable.reload.payload[NutriScaleReview::FEEDBACK]).to eq("Off topic")
    end

    it "keeps ordinary rejection free of a fabricated feedback reason" do
      reviewable = Fabricate(:reviewable_queued_post_topic, target_created_by: author)
      reviewable.perform(admin, :reject_post)

      expect(reviewable.reload).to be_rejected
      json = ReviewableQueuedPostSerializer.new(reviewable, scope: admin.guardian, root: false).as_json
      expect(json).not_to have_key(:nutriscale_review_feedback)
      expect(json[:nutriscale_can_resubmit]).to eq(true)
    end
  end
end

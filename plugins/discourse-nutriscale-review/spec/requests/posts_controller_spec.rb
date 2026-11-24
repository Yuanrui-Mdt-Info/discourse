# frozen_string_literal: true

RSpec.describe PostsController do
  fab!(:author) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:admin)
  fab!(:category)

  describe "#create" do
    it "accepts the plugin parameter through the native post endpoint" do
      original = Fabricate(:reviewable_queued_post_topic, target_created_by: author, category: category)
      original.perform(admin, :reject_post)
      SiteSetting.approve_unless_allowed_groups = "1|2"
      sign_in(author)

      post "/posts.json", params: {
        title: "Revised recipe from the post API",
        raw: "The updated recipe includes all ingredients and preparation instructions.",
        category: category.id,
        nested_post: true,
        nutriscale_reviewable_id: original.id,
      }

      expect(response.status).to eq(200)
      expect(response.parsed_body["action"]).to eq("enqueued")
      expect(original.reload.payload[NutriScaleReview::REPLACEMENT_REVIEWABLE]).to eq(
        response.parsed_body.dig("pending_post", "id"),
      )
    end
  end
end

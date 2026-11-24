# frozen_string_literal: true

require "new_post_manager"

RSpec.describe NewPostManager do
  fab!(:author) { Fabricate(:user, refresh_auto_groups: true) }
  fab!(:other_author, :user)
  fab!(:category)
  let!(:original) do
    Fabricate(
      :reviewable_queued_post_topic,
      target_created_by: author,
      category: category,
      status: Reviewable.statuses[:rejected],
    )
  end

  def manager(user = author, title = "Revised nutrition recipe")
    NewPostManager.new(
      user,
      title: title,
      raw: "Revised recipe with complete ingredients and detailed preparation instructions.",
      category: category.id,
      nutriscale_reviewable_id: original.id,
    )
  end

  describe "#perform" do
    it "queues the revised topic once and links the original rejected record" do
      SiteSetting.approve_unless_allowed_groups = "1|2"
      result = manager.perform

      expect(result).to be_success
      expect(result.action).to eq(:enqueued)
      expect(original.reload.payload[NutriScaleReview::REPLACEMENT_REVIEWABLE]).to eq(result.reviewable.id)
      expect(result.reviewable.target_created_by_id).to eq(author.id)
      expect { manager.perform }.to raise_error(Discourse::InvalidAccess)
      expect(ReviewableQueuedPost.where(target_created_by: author).count).to eq(2)
    end

    it "records the public topic when normal site rules publish the revised post immediately" do
      SiteSetting.approve_unless_allowed_groups = "0"
      SiteSetting.approve_new_topics_unless_allowed_groups = "0"
      result = manager.perform

      expect(result).to be_success
      expect(result.post.user_id).to eq(author.id)
      expect(original.reload.payload[NutriScaleReview::REPLACEMENT_TOPIC]).to eq(result.post.topic_id)
      expect { manager.perform }.to raise_error(Discourse::InvalidAccess)
    end

    it "rejects another author's request without creating any content" do
      expect { manager(other_author).perform }.to raise_error(Discourse::InvalidAccess)
      expect(original.reload.payload).not_to have_key(NutriScaleReview::REPLACEMENT_REVIEWABLE)
      expect(original.payload).not_to have_key(NutriScaleReview::REPLACEMENT_TOPIC)
    end

    it "keeps the original available after normal content validation refuses a revision" do
      result = manager(author, "").perform

      expect(result.success?).to eq(false)
      expect(original.reload.payload).not_to have_key(NutriScaleReview::REPLACEMENT_REVIEWABLE)
      expect(original.payload).not_to have_key(NutriScaleReview::REPLACEMENT_TOPIC)
    end

    it "does not change ordinary post creation without a rejected draft id" do
      SiteSetting.approve_unless_allowed_groups = "0"
      SiteSetting.approve_new_topics_unless_allowed_groups = "0"
      result = NewPostManager.new(
        author,
        title: "An ordinary nutrition topic",
        raw: "Complete ingredients and preparation instructions for the ordinary recipe.",
        category: category.id,
      ).perform

      expect(result).to be_success
      expect(result.post.user_id).to eq(author.id)
      expect(original.reload.payload).not_to have_key(NutriScaleReview::REPLACEMENT_TOPIC)
    end

    it "does not turn a rejected public topic into a private message" do
      request = manager
      request.args[:archetype] = Archetype.private_message

      expect { request.perform }.to raise_error(Discourse::InvalidParameters)
      expect(original.reload.payload).not_to have_key(NutriScaleReview::REPLACEMENT_TOPIC)
    end

    it "keeps pending and queued replies outside resubmission" do
      original.update!(status: Reviewable.statuses[:pending])
      expect { manager.perform }.to raise_error(Discourse::InvalidAccess)
      original.update!(status: Reviewable.statuses[:rejected], topic: Fabricate(:topic))
      expect { manager.perform }.to raise_error(Discourse::InvalidAccess)
    end
  end
end

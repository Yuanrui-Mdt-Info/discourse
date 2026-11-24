# frozen_string_literal: true

module ::NutriScaleReview
  module ResubmissionExtension
    def perform
      return super if args[:nutriscale_reviewable_id].blank?

      reviewable_id = Integer(args[:nutriscale_reviewable_id], exception: false)
      if reviewable_id.nil? || reviewable_id <= 0 || args[:topic_id].present? ||
           args[:archetype] == Archetype.private_message
        raise Discourse::InvalidParameters.new(:nutriscale_reviewable_id)
      end
      original = ReviewableQueuedPost.find_by(id: reviewable_id)
      raise Discourse::InvalidAccess if original.nil?

      original.with_lock do
        if original.target_created_by_id != user.id || !original.rejected? ||
             original.topic_id.present? ||
             original.payload[NutriScaleReview::REPLACEMENT_REVIEWABLE].present? ||
             original.payload[NutriScaleReview::REPLACEMENT_TOPIC].present?
          raise Discourse::InvalidAccess
        end

        result = super
        if result.success?
          replacement =
            if result.action == :enqueued
              { NutriScaleReview::REPLACEMENT_REVIEWABLE => result.reviewable.id }
            else
              { NutriScaleReview::REPLACEMENT_TOPIC => result.post.topic_id }
            end
          original.update!(payload: original.payload.merge(replacement))
        end
        result
      end
    end
  end
end

# frozen_string_literal: true

# name: discourse-nutriscale-review
# about: Preserve author feedback and link resubmitted queued topics for NutriScale.
# version: 0.1
# authors: NutriScale

module ::NutriScaleReview
  FEEDBACK = "nutriscale_review_feedback"
  REPLACEMENT_REVIEWABLE = "nutriscale_replacement_reviewable_id"
  REPLACEMENT_TOPIC = "nutriscale_replacement_topic_id"
end

after_initialize do
  require "new_post_manager"
  require_relative "lib/nutriscale_review/queued_post_extension"
  require_relative "lib/nutriscale_review/resubmission_extension"

  add_permitted_post_create_param(:nutriscale_reviewable_id)
  ReviewableQueuedPost.prepend(NutriScaleReview::QueuedPostExtension)
  NewPostManager.prepend(NutriScaleReview::ResubmissionExtension)

  [
    NutriScaleReview::FEEDBACK,
    NutriScaleReview::REPLACEMENT_REVIEWABLE,
    NutriScaleReview::REPLACEMENT_TOPIC,
  ].each do |field|
    add_to_serializer(
      :reviewable_queued_post,
      field.to_sym,
      include_condition: -> { object.payload[field].present? },
    ) { object.payload[field] }
  end

  add_to_serializer(:reviewable_queued_post, :nutriscale_can_resubmit) do
    object.rejected? && object.topic_id.blank? &&
      object.payload[NutriScaleReview::REPLACEMENT_REVIEWABLE].blank? &&
      object.payload[NutriScaleReview::REPLACEMENT_TOPIC].blank?
  end
end

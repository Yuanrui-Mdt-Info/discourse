# frozen_string_literal: true

module ::NutriScaleReview
  module QueuedPostExtension
    def perform_revise_and_reject_post(performed_by, args)
      result = super
      if result.success?
        feedback =
          args[:revise_feedback].presence || args[:revise_custom_reason].presence ||
            args[:revise_reason]
        self.payload = payload.merge(NutriScaleReview::FEEDBACK => feedback)
      end
      result
    end

    def perform_reject_post(performed_by, args)
      result = super
      self.payload = payload.except(NutriScaleReview::FEEDBACK) if result.success?
      result
    end
  end
end

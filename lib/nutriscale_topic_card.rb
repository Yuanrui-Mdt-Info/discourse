# frozen_string_literal: true

class NutriscaleTopicCard
  def self.build(post)
    document = Nokogiri::HTML5.fragment(post.cooked.to_s)
    document.css("pre code.lang-nutricircle-challenge").each { |code| code.parent.remove }
    document.css(".quote, .onebox, .spoiler, details").remove

    media =
      document
        .css("img[src], video, .video-placeholder-container[data-video-src]")
        .filter_map do |node|
          next if node.ancestors.any? do |ancestor|
            ancestor.element? && ancestor.matches?("video, .video-placeholder-container")
          end
          next if node.key?(PrettyText::BLOCKED_HOTLINKED_SRC_ATTR)

          if node.name == "img"
            next if node.matches?(".emoji, .site-icon, .onebox-avatar, .onebox-avatar-inline")

            lightbox =
              node.ancestors.find do |ancestor|
                ancestor.element? && ancestor.matches?("a.lightbox")
              end
            url = lightbox&.[]("href").presence || node["src"]
            { kind: "image", url: url } if url.present?
          else
            url =
              node["data-video-src"].presence || node["src"].presence ||
                node.at_css("source[src]")&.[]("src")
            next if url.blank? || url == "/404"

            {
              kind: "video",
              url: url,
              poster_url: node["data-thumbnail-src"].presence || node["poster"].presence,
            }
          end
        end

    document.css(".lightbox-wrapper .meta, video, .video-placeholder-container").remove
    excerpt =
      Post.excerpt(
        document.to_html,
        SiteSetting.topic_excerpt_maxlength,
        strip_links: true,
        strip_images: true,
        text_entities: true,
        plain_hashtags: true,
      ).squish

    { post_id: post.id, excerpt: excerpt, media: media.uniq { |item| [item[:kind], item[:url]] } }
  end
end

# frozen_string_literal: true

RSpec.describe TopicListItemSerializer do
  let(:topic) do
    date = Time.zone.now

    Fabricate(
      :topic,
      title: "This is a test topic title",
      created_at: date - 2.minutes,
      bumped_at: date,
    )
  end

  it "correctly serializes topic" do
    SiteSetting.topic_featured_link_enabled = true
    serialized = TopicListItemSerializer.new(topic, scope: Guardian.new, root: false).as_json

    expect(serialized[:title]).to eq("This is a test topic title")
    expect(serialized[:bumped]).to eq(true)
    expect(serialized[:featured_link]).to eq(nil)
    expect(serialized[:featured_link_root_domain]).to eq(nil)

    featured_link = "http://meta.discourse.org"
    topic.featured_link = featured_link
    serialized = TopicListItemSerializer.new(topic, scope: Guardian.new, root: false).as_json

    expect(serialized[:featured_link]).to eq(featured_link)
    expect(serialized[:featured_link_root_domain]).to eq("discourse.org")
  end

  describe "#nutriscale_card" do
    fab!(:author, :user)
    fab!(:first_post) { Fabricate(:post, user: author) }
    let(:card_topic) { first_post.topic }
    let(:serializer) { described_class.new(card_topic, scope: Guardian.new, root: false) }

    it "returns first-post text and ordered media without metadata or duplicate lightbox images" do
      first_post.update_columns(cooked: <<~HTML)
        <p>Breakfast &amp; lunch.</p>
        <pre><code class="lang-nutricircle-challenge">{"entryTag":"challenge-19"}</code></pre>
        <div class="lightbox-wrapper">
          <a class="lightbox" href="/uploads/breakfast.jpg">
            <img src="/uploads/breakfast-small.jpg">
            <div class="meta">breakfast.jpg 100 KB</div>
          </a>
        </div>
        <div class="video-placeholder-container" data-video-src="/uploads/breakfast.mp4" data-thumbnail-src="/uploads/poster.jpg">
          <img src="/uploads/poster.jpg"><span>Play video</span>
        </div>
        <img src="/uploads/breakfast.jpg">
      HTML
      Fabricate(:post, topic: card_topic, cooked: '<p>Reply</p><img src="/uploads/reply.jpg">')

      expect(serializer.as_json[:nutriscale_card]).to eq(
        post_id: first_post.id,
        challenge_id: nil,
        liked: false,
        can_like: false,
        excerpt: "Breakfast & lunch.",
        media: [
          { kind: "image", url: "/uploads/breakfast.jpg" },
          { kind: "video", url: "/uploads/breakfast.mp4", poster_url: "/uploads/poster.jpg" },
        ],
      )
    end

    it "supports video sources and excludes quoted, collapsed, decorative and blocked media" do
      first_post.update_columns(cooked: <<~HTML)
        <p>Breakfast</p>
        <img class="emoji" src="/emoji/smile.png" alt=":smile:">
        <img class="site-icon" src="/icon.png">
        <aside class="quote"><img src="/quoted.jpg"></aside>
        <aside class="onebox"><img src="/preview.jpg"></aside>
        <details><summary>Hidden</summary><img src="/details.jpg"></details>
        <span class="spoiler"><img src="/spoiler.jpg"></span>
        <video src="/uploads/first.mp4" poster="/uploads/cover.jpg"></video>
        <video><source src="/uploads/second.mp4"><img src="/fallback.jpg"></video>
        <div class="video-placeholder-container" data-video-src="/404"></div>
        <div class="video-placeholder-container" data-video-src="https://blocked.example/video.mp4" #{PrettyText::BLOCKED_HOTLINKED_SRC_ATTR}="https://blocked.example/video.mp4"></div>
      HTML

      expect(serializer.as_json[:nutriscale_card][:media]).to eq(
        [
          { kind: "video", url: "/uploads/first.mp4", poster_url: "/uploads/cover.jpg" },
          { kind: "video", url: "/uploads/second.mp4", poster_url: nil },
        ],
      )
    end

    it "includes video attachment links using native video types and preserves normal links" do
      first_post.update_columns(cooked: <<~HTML)
        <p>Breakfast <a href="https://example.com/recipe">recipe</a></p>
        <p><a href="//example.com/uploads/breakfast.MP4?download=1">breakfast.mp4</a></p>
        <p><a class="onebox" href="/uploads/breakfast.webm">breakfast.webm</a></p>
      HTML

      expect(serializer.as_json[:nutriscale_card]).to eq(
        post_id: first_post.id,
        challenge_id: nil,
        liked: false,
        can_like: false,
        excerpt: "Breakfast recipe",
        media: [
          { kind: "video", url: "//example.com/uploads/breakfast.MP4?download=1", poster_url: nil },
          { kind: "video", url: "/uploads/breakfast.webm", poster_url: nil },
        ],
      )
    end

    it "uses the current first post and native excerpt length for text-only cards" do
      SiteSetting.topic_excerpt_maxlength = 20
      first_post.update_columns(cooked: "<p>#{"breakfast " * 10}</p>")
      initial_card = serializer.as_json[:nutriscale_card]
      expect(initial_card[:excerpt]).to end_with("...")
      expect(initial_card[:media]).to eq([])

      first_post.update_columns(cooked: "<p>Updated breakfast</p>")
      updated_card =
        described_class.new(card_topic.reload, scope: Guardian.new, root: false).as_json
      expect(updated_card[:nutriscale_card][:excerpt]).to eq("Updated breakfast")
    end

    it "hides flagged content from anonymous users and authors while allowing staff" do
      first_post.update!(hidden: true)
      expect(serializer.as_json[:nutriscale_card]).to eq(nil)
      author_json = described_class.new(card_topic, scope: author.guardian, root: false).as_json
      expect(author_json[:nutriscale_card]).to eq(nil)

      staff_json =
        described_class.new(card_topic, scope: Fabricate(:admin).guardian, root: false).as_json
      expect(staff_json[:nutriscale_card][:post_id]).to eq(first_post.id)
    end

    it "returns null for missing or deleted first posts" do
      missing_post_json = described_class.new(topic, scope: Guardian.new, root: false).as_json
      expect(missing_post_json[:nutriscale_card]).to eq(nil)

      first_post.trash!
      expect(serializer.as_json[:nutriscale_card]).to eq(nil)
    end

    it "reads the activity marker from the first post rather than a reply or tag" do
      first_post.update_columns(raw: "Breakfast\n<!-- nutricircle-challenge:19 -->")
      Fabricate(:post, topic: card_topic, raw: "Reply\n<!-- nutricircle-challenge:20 -->")
      expect(serializer.nutriscale_card[:challenge_id]).to eq(19)
    end

    it "uses native like permissions for guests, authors, other users and archived topics" do
      reader = Fabricate(:user)
      expect(serializer.nutriscale_card).to include(liked: false, can_like: false)
      author_card = described_class.new(card_topic, scope: author.guardian).nutriscale_card
      expect(author_card).to include(liked: false, can_like: false)
      reader_card = described_class.new(card_topic, scope: reader.guardian).nutriscale_card
      expect(reader_card).to include(liked: false, can_like: true)

      PostActionCreator.like(reader, first_post)
      liked_card = described_class.new(card_topic, scope: reader.guardian).nutriscale_card
      expect(liked_card).to include(liked: true, can_like: false)

      card_topic.update!(archived: true)
      other_card = described_class.new(card_topic, scope: Fabricate(:user).guardian).nutriscale_card
      expect(other_card).to include(liked: false, can_like: false)
    end

    it "denies likes for silenced users" do
      reader = Fabricate(:user, silenced_till: 1.day.from_now)
      card = described_class.new(card_topic, scope: reader.guardian).nutriscale_card
      expect(card).to include(liked: false, can_like: false)
    end

    it "loads likes once for the whole list and keeps them specific to each viewer" do
      reader = Fabricate(:user)
      another_post = Fabricate(:post)
      PostActionCreator.like(reader, first_post)
      topic_ids = [first_post.topic_id, another_post.topic_id]
      list = TopicQuery.new(reader).list_latest
      list.topics
      guardian = reader.guardian
      cards = nil
      queries =
        track_sql_queries do
          cards =
            list.topics.map { |entry| described_class.new(entry, scope: guardian).nutriscale_card }
        end
      expect(cards.find { |card| card[:post_id] == first_post.id }).to include(
        liked: true,
        can_like: false,
      )
      expect(cards.find { |card| card[:post_id] == another_post.id }).to include(
        liked: false,
        can_like: true,
      )
      expect(queries.grep(/FROM "post_actions"/i).size).to eq(1)
      expect(queries.grep(/FROM "posts"/i)).to eq([])

      other_reader = Fabricate(:user)
      other_list = TopicQuery.new(other_reader).list_latest
      other_cards =
        other_list
          .topics
          .select { |entry| topic_ids.include?(entry.id) }
          .map { |entry| described_class.new(entry, scope: other_reader.guardian).nutriscale_card }
      expect(other_cards.map { |card| card[:liked] }).to eq([false, false])
    end

    it "does not query the database when serializing preloaded first posts" do
      another_post = Fabricate(:post)
      topics =
        Topic.where(id: [first_post.topic_id, another_post.topic_id]).includes(:first_post).to_a
      serializers =
        topics.map { |entry| described_class.new(entry, scope: Guardian.new, root: false) }
      serializers.each(&:nutriscale_card)

      queries = track_sql_queries { serializers.each(&:nutriscale_card) }
      expect(queries).to eq([])
    end
  end

  describe "when topic featured link is disable" do
    before { SiteSetting.topic_featured_link_enabled = false }

    it "omits the topic's featured link" do
      topic.featured_link = "http://meta.discourse.org"
      serialized = TopicListItemSerializer.new(topic, scope: Guardian.new, root: false).as_json

      expect(serialized[:featured_link]).to eq(nil)
      expect(serialized[:featured_link_root_domain]).to eq(nil)
    end
  end

  describe "hidden tags" do
    let(:admin) { Fabricate(:admin) }
    let(:user) { Fabricate(:user) }
    let(:hidden_tag) { Fabricate(:tag, name: "hidden", description: "a" * 1000) }
    let(:staff_tag_group) do
      Fabricate(:tag_group, permissions: { "staff" => 1 }, tag_names: [hidden_tag.name])
    end

    before do
      SiteSetting.tagging_enabled = true
      staff_tag_group
      topic.tags << hidden_tag
    end

    it "returns hidden tag to staff" do
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(admin), root: false).as_json

      expect(json[:tags]).to eq(
        [{ id: hidden_tag.id, name: hidden_tag.name, slug: hidden_tag.slug }],
      )
    end

    it "trucates description" do
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(admin), root: false).as_json
      expect(json[:tags_descriptions]).to eq({ "hidden" => "a" * 77 + "..." })
    end

    it "does not return hidden tag to non-staff" do
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(user), root: false).as_json

      expect(json[:tags]).to eq([])
    end

    it "accepts an option to remove hidden tags" do
      json =
        TopicListItemSerializer.new(
          topic,
          scope: Guardian.new(user),
          hidden_tag_names: [hidden_tag.name],
          root: false,
        ).as_json

      expect(json[:tags]).to eq([])
    end

    it "return posters" do
      json =
        TopicListItemSerializer.new(
          topic,
          scope: Guardian.new(user),
          hidden_tag_names: [hidden_tag.name],
          root: false,
        ).as_json

      expect(json[:posters].length).to eq(1)
    end

    it "uses slug_for_url for tags with empty slugs" do
      numeric_tag = Fabricate(:tag, name: "7")
      expect(numeric_tag.slug).to eq("")

      topic.tags << numeric_tag
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(admin), root: false).as_json
      entry = json[:tags].find { |t| t[:id] == numeric_tag.id }

      expect(entry[:slug]).to eq("#{numeric_tag.id}-tag")
    end
  end

  describe "correctly serializes op_likes data" do
    let(:user) { Fabricate(:user) }
    let(:moderator) { Fabricate(:moderator) }
    let(:first_post) { Fabricate(:post, topic: topic, user: user) }
    let(:plugin) { Plugin::Instance.new }

    before { topic.update!(first_post: first_post) }

    it "serializes op_can_like when theme modifies the serialize_topic_op_likes_data to true" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(true)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json[:op_can_like]).to eq(true)
    end

    it "does not include op_can_like when theme modifier disallows" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(false)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json.key?(:op_can_like)).to eq(false)
    end

    it "serializes op_can_like when plugin modifies the serialize_topic_op_likes_data to true" do
      modifier = :serialize_topic_op_likes_data
      proc = Proc.new { true }
      DiscoursePluginRegistry.register_modifier(plugin, modifier, &proc)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json.key?(:op_can_like)).to eq(true)
    ensure
      DiscoursePluginRegistry.unregister_modifier(plugin, modifier, &proc)
    end

    it "serializes op_liked when theme modifies the serialize_topic_op_likes_data to true" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(true)
      PostAction.create!(
        user: user,
        post: first_post,
        post_action_type_id: PostActionType.types[:like],
      )
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(user), root: false).as_json

      expect(json[:op_liked]).to eq(true)
    end

    it "does not include op_liked when theme modifier disallows" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(false)
      PostAction.create!(
        user: user,
        post: first_post,
        post_action_type_id: PostActionType.types[:like],
      )
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(user), root: false).as_json

      expect(json.key?(:op_liked)).to eq(false)
    end

    it "serializes op_liked when plugin modifies the serialize_topic_op_likes_data to true" do
      modifier = :serialize_topic_op_likes_data
      proc = Proc.new { true }
      DiscoursePluginRegistry.register_modifier(plugin, modifier, &proc)
      PostAction.create!(
        user: user,
        post: first_post,
        post_action_type_id: PostActionType.types[:like],
      )
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(user), root: false).as_json

      expect(json[:op_liked]).to eq(true)
    ensure
      DiscoursePluginRegistry.unregister_modifier(plugin, modifier, &proc)
    end

    it "serializes first_post_id when theme modifies the serialize_topic_op_likes_data to true" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(true)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json[:first_post_id]).to eq(first_post.id)
    end

    it "does not include first_post_id when theme modifier disallows" do
      allow_any_instance_of(ThemeModifierHelper).to receive(
        :serialize_topic_op_likes_data,
      ).and_return(false)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json.key?(:first_post_id)).to eq(false)
    end

    it "serializes first_post_id when plugin modifies the serialize_topic_op_likes_data to true" do
      modifier = :serialize_topic_op_likes_data
      proc = Proc.new { true }
      DiscoursePluginRegistry.register_modifier(plugin, modifier, &proc)
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json

      expect(json[:first_post_id]).to eq(first_post.id)
    ensure
      DiscoursePluginRegistry.unregister_modifier(plugin, modifier, &proc)
    end

    it "serializes op_like_count" do
      json = TopicListItemSerializer.new(topic, scope: Guardian.new(moderator), root: false).as_json
      expect(json[:op_like_count]).to eq(first_post.like_count)
    end
  end

  describe "tag localization" do
    fab!(:user)
    fab!(:localized_tag, :tag) { Fabricate(:tag, name: "cats", locale: "en") }
    fab!(:localization) do
      Fabricate(
        :tag_localization,
        tag: localized_tag,
        locale: "ja",
        name: "猫",
        description: "猫についてのタグです",
      )
    end

    before do
      SiteSetting.tagging_enabled = true
      topic.tags << localized_tag
    end

    def serialize
      TopicListItemSerializer.new(topic, scope: Guardian.new(user), root: false).as_json
    end

    it "returns localized tag name when conditions met" do
      SiteSetting.content_localization_enabled = true
      localized_tag.update!(locale: "en")
      I18n.locale = "ja"

      expect(serialize[:tags]).to include(
        { id: localized_tag.id, name: "猫", slug: localized_tag.slug },
      )
    end

    it "returns original tag name when localization disabled" do
      SiteSetting.content_localization_enabled = false
      I18n.locale = "ja"

      expect(serialize[:tags]).to include(
        { id: localized_tag.id, name: "cats", slug: localized_tag.slug },
      )
    end

    it "returns original tag name when tag has no locale" do
      SiteSetting.content_localization_enabled = true
      localized_tag.update!(locale: nil)
      I18n.locale = "ja"

      expect(serialize[:tags]).to include(
        { id: localized_tag.id, name: "cats", slug: localized_tag.slug },
      )
    end

    it "uses localized tag name as key in tags_descriptions" do
      SiteSetting.content_localization_enabled = true
      localized_tag.update!(locale: "en", description: "A tag about cats")
      I18n.locale = "ja"

      expect(serialize[:tags_descriptions]).to have_key("猫")
      expect(serialize[:tags_descriptions]).not_to have_key("cats")
      expect(serialize[:tags_descriptions]["猫"]).to eq("猫についてのタグです")
    end

    it "uses original tag name as key when localization disabled" do
      SiteSetting.content_localization_enabled = false
      localized_tag.update!(description: "A tag about cats")
      I18n.locale = "ja"

      expect(serialize[:tags_descriptions]).to have_key("cats")
      expect(serialize[:tags_descriptions]).not_to have_key("猫")
      expect(serialize[:tags_descriptions]["cats"]).to eq("A tag about cats")
    end
  end

  describe "#has_new_replies" do
    fab!(:user)
    fab!(:other_user, :user)
    fab!(:nested_topic_record, :topic) { Fabricate(:topic, user: other_user) }

    before do
      SiteSetting.nested_replies_enabled = true
      Fabricate(:nested_topic, topic: nested_topic_record)
    end

    def serialize_with_user_data(last_visited_at:)
      nested_topic_record.user_data =
        TopicUser
          .find_or_create_by(user: user, topic: nested_topic_record)
          .tap { |tu| tu.update!(last_visited_at: last_visited_at) }
      TopicListItemSerializer.new(
        nested_topic_record,
        scope: Guardian.new(user),
        root: false,
      ).as_json
    end

    it "is included when bumped_at is after last_visited_at and the user wasn't the last poster" do
      nested_topic_record.update!(bumped_at: 1.minute.ago, last_post_user_id: other_user.id)
      json = serialize_with_user_data(last_visited_at: 5.minutes.ago)

      expect(json[:has_new_replies]).to eq(true)
    end

    it "is omitted when last_visited_at is more recent than bumped_at" do
      nested_topic_record.update!(bumped_at: 5.minutes.ago, last_post_user_id: other_user.id)
      json = serialize_with_user_data(last_visited_at: 1.minute.ago)

      expect(json.key?(:has_new_replies)).to eq(false)
    end

    it "is omitted when the current user was the last poster" do
      nested_topic_record.update!(bumped_at: 1.minute.ago, last_post_user_id: user.id)
      json = serialize_with_user_data(last_visited_at: 5.minutes.ago)

      expect(json.key?(:has_new_replies)).to eq(false)
    end

    it "is omitted when the user has never visited the topic" do
      nested_topic_record.update!(bumped_at: 1.minute.ago, last_post_user_id: other_user.id)
      json = serialize_with_user_data(last_visited_at: nil)

      expect(json.key?(:has_new_replies)).to eq(false)
    end

    it "is omitted from the payload for flat topics" do
      flat_topic = Fabricate(:topic, user: other_user)
      flat_topic.user_data =
        TopicUser
          .find_or_create_by(user: user, topic: flat_topic)
          .tap { |tu| tu.update!(last_visited_at: 5.minutes.ago) }

      json = TopicListItemSerializer.new(flat_topic, scope: Guardian.new(user), root: false).as_json

      expect(json.key?(:has_new_replies)).to eq(false)
    end

    it "is omitted from the payload when the user is anonymous" do
      json =
        TopicListItemSerializer.new(nested_topic_record, scope: Guardian.new, root: false).as_json

      expect(json.key?(:has_new_replies)).to eq(false)
    end

    it "leaves the existing flat-topic unread payload (unread_posts, unseen) intact" do
      flat_topic = Fabricate(:topic, user: other_user, bumped_at: 1.minute.ago)
      Fabricate(:post, topic: flat_topic, user: other_user)
      Fabricate(:post, topic: flat_topic, user: other_user)
      flat_topic.reload
      flat_topic.user_data =
        TopicUser
          .find_or_create_by(user: user, topic: flat_topic)
          .tap do |tu|
            tu.update!(
              last_visited_at: 5.minutes.ago,
              last_read_post_number: 1,
              notification_level: TopicUser.notification_levels[:watching],
            )
          end

      json = TopicListItemSerializer.new(flat_topic, scope: Guardian.new(user), root: false).as_json

      expect(json[:unread_posts]).to be > 0
      expect(json.key?(:unseen)).to eq(true)
      expect(json.key?(:has_new_replies)).to eq(false)
    end
  end

  describe "#is_hot" do
    describe "including the attr based on theme modifier or plugin registry" do
      fab!(:hot_topic, :topic)

      # Caching this directly to workaround the limit heuristic.
      before { Discourse.cache.write(TopicHotScore::CACHE_KEY, Set.new([hot_topic.id])) }
      after { Discourse.cache.delete(TopicHotScore::CACHE_KEY) }

      context "without opt-in" do
        before do
          allow_any_instance_of(ThemeModifierHelper).to receive(:serialize_topic_is_hot).and_return(
            false,
          )
        end

        it "doesn't includes the attr" do
          serialized =
            TopicListItemSerializer.new(hot_topic, scope: Guardian.new, root: false).as_json

          expect(serialized.key?(:is_hot)).to eq(false)
        end
      end

      context "when theme modifier opts-in" do
        before do
          allow_any_instance_of(ThemeModifierHelper).to receive(:serialize_topic_is_hot).and_return(
            true,
          )
        end

        it "returns true if topic is hot" do
          serialized =
            TopicListItemSerializer.new(hot_topic, scope: Guardian.new, root: false).as_json

          expect(serialized[:is_hot]).to eq(true)
        end

        it "returns false if topic is not hot" do
          serialized = TopicListItemSerializer.new(topic, scope: Guardian.new, root: false).as_json

          expect(serialized[:is_hot]).to eq(false)
        end
      end

      context "when plugin registry opts-in" do
        let(:modifier) { :serialize_topic_is_hot }
        let(:proc) { Proc.new { true } }
        let(:plugin) { Plugin::Instance.new }

        before { DiscoursePluginRegistry.register_modifier(plugin, modifier, &proc) }
        after { DiscoursePluginRegistry.unregister_modifier(plugin, modifier, &proc) }

        it "returns true if topic is hot" do
          serialized =
            TopicListItemSerializer.new(hot_topic, scope: Guardian.new, root: false).as_json

          expect(serialized[:is_hot]).to eq(true)
        end

        it "returns false if topic is not hot" do
          serialized = TopicListItemSerializer.new(topic, scope: Guardian.new, root: false).as_json

          expect(serialized[:is_hot]).to eq(false)
        end
      end
    end
  end
end

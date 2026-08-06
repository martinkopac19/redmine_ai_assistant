# frozen_string_literal: true

module RedmineAiAssistant
  class Hooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(_context = {})
      return '' unless User.current.logged? && RedmineAiAssistant.usable?

      out = +''
      out << stylesheet_link_tag('ai_assistant', :plugin => 'redmine_ai_assistant')
      out << javascript_tag("window.RAA_CONFIG=#{js_config.to_json};")
      out.html_safe
    end

    def view_layouts_base_body_bottom(_context = {})
      return '' unless User.current.logged? && RedmineAiAssistant.usable?

      javascript_include_tag('ai_assistant', :plugin => 'redmine_ai_assistant').html_safe
    end

    # Tlačidlá pod poľom komentára.
    render_on :view_issues_edit_notes_bottom,
              :partial => 'ai_assistant/issue_actions'

    # Tlačidlo AI Summarizer. Lišta akcií (Edit / Log time / Watch / Copy) je
    # Redmine partial `issues/_action_menu` a hook v nej ŽIADNY nie je, takže sa
    # do nej serverovo dostať nedá — presúva ho tam JS. Renderujeme v
    # `view_issues_show_details_bottom`, ktorý je (na rozdiel od
    # `view_issues_edit_notes_bottom` v skrytom #update) vždy viditeľný, takže
    # keby presun nevyšiel, tlačidlo je aspoň dostupné pod detailom.
    render_on :view_issues_show_details_bottom,
              :partial => 'ai_assistant/issue_summary_button'

    private

    # Len to, čo JS naozaj používa. Žiadny SQL dotaz — o tom, či sa tlačidlá
    # zobrazia, rozhodujú partialy na serveri, nie JS.
    def js_config
      {
        :base          => Redmine::Utils.relative_url_root.to_s,
        :suggestPath   => '/ai_assistant/suggest',
        :summaryPath   => '/ai_assistant/summary',
        # Texty overlayu — okno stavia JS, takže ich nemá odkiaľ vziať z ERB.
        # `%{issue}` doplní JS číslom a názvom úlohy.
        :i18n          => {
          :close        => l(:'ai_assistant.close'),
          :summaryTitle => l(:'ai_assistant.summary_title', :issue => '%{issue}')
        }
      }
    end
  end
end

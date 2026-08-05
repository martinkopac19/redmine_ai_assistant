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

    private

    # Len to, čo JS naozaj používa. Žiadny SQL dotaz — o tom, či sa tlačidlá
    # zobrazia, rozhodujú partialy na serveri, nie JS.
    def js_config
      {
        :base          => Redmine::Utils.relative_url_root.to_s,
        :suggestPath   => '/ai_assistant/suggest'
      }
    end
  end
end

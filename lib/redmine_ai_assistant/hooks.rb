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

    # Tlačidlo „Create with AI" patrí k nadpisu „New issue“.
    #
    # `view_issues_new_top` je hneď za `<h2>New issue</h2>` a — čo je dôležitejšie —
    # MIMO formulára: zmena trackera alebo kategórie prekreslí `#all_attributes`
    # zo servera, takže tlačidlo renderované vnútri formulára by sa pri každom
    # takom prekreslení objavilo znova. Odtiaľto ho JS presunie k nadpisu a zostane
    # tam. Hook sa navyše volá len na stránke novej úlohy, nie pri editácii.
    render_on :view_issues_new_top,
              :partial => 'ai_assistant/new_issue_button'

    private

    # Len to, čo JS naozaj používa. Žiadny SQL dotaz — o tom, či sa tlačidlá
    # zobrazia, rozhodujú partialy na serveri, nie JS.
    def js_config
      {
        :base          => Redmine::Utils.relative_url_root.to_s,
        :suggestPath   => '/ai_assistant/suggest',
        :summaryPath   => '/ai_assistant/summary',
        :draftPath     => '/ai_assistant/draft_issue',
        :planPath        => '/ai_assistant/plan_issues',
        :planContextPath => '/ai_assistant/plan_context',
        # Projekt stránky, na ktorej okno vzniká — v layoute je zadarmo, žiadny
        # dotaz. Na globálnych stránkach je nil a okno padne na naposledy
        # použitý projekt z localStorage.
        :projectId     => (defined?(@project) ? @project&.id : nil),
        # Texty overlayu — okno stavia JS, takže ich nemá odkiaľ vziať z ERB.
        # `%{issue}` doplní JS číslom a názvom úlohy.
        :i18n          => {
          :close         => l(:'ai_assistant.close'),
          :summaryTitle  => l(:'ai_assistant.summary_title', :issue => '%{issue}'),
          :draftFilled   => l(:'ai_assistant.draft_filled'),
          :draftSimilar  => l(:'ai_assistant.draft_similar'),
          :draftQuestions => l(:'ai_assistant.draft_questions'),
          :draftWorking  => l(:'ai_assistant.draft_working'),
          :draftTitle    => l(:'ai_assistant.draft_modal_title'),
          :draftApply    => l(:'ai_assistant.draft_apply'),
          :draftRecalc   => l(:'ai_assistant.draft_recalc'),
          :draftAnswer   => l(:'ai_assistant.draft_answer_placeholder'),
          :draftProjectChanged => l(:'ai_assistant.draft_project_changed', :project => '%{project}'),
          :plan          => {
            :title       => l(:'ai_assistant.button_plan'),
            # `%{keys}` doplní JS — Mac ukazuje ⇧⌘X, ostatné Ctrl+Shift+X.
            :shortcutHint => l(:'ai_assistant.plan_shortcut_hint', :keys => '%{keys}'),
            :inputLabel  => l(:'ai_assistant.plan_input_label'),
            :placeholder => l(:'ai_assistant.plan_input_placeholder'),
            :projectLock => l(:'ai_assistant.plan_project_lock'),
            :submit      => l(:'ai_assistant.plan_submit'),
            :refine      => l(:'ai_assistant.plan_refine'),
            :accept      => l(:'ai_assistant.plan_accept'),
            :working     => l(:'ai_assistant.plan_working'),
            :heading     => l(:'ai_assistant.plan_heading'),
            :parent      => l(:'ai_assistant.plan_parent'),
            :subtask     => l(:'ai_assistant.plan_subtask'),
            :standalone  => l(:'ai_assistant.plan_standalone'),
            :noSubtasks  => l(:'ai_assistant.plan_no_subtasks', :project => '%{project}'),
            :empty       => l(:'ai_assistant.error_plan_empty'),
            :noResult    => l(:'ai_assistant.error_plan_no_result'),
            # Sprievodca zakladaním. `%{done}`, `%{total}` a `%{subject}` dopĺňa JS.
            :queueProgress      => l(:'ai_assistant.plan_queue_progress',
                                     :done => '%{done}', :total => '%{total}'),
            :queueNext          => l(:'ai_assistant.plan_queue_next', :subject => '%{subject}'),
            :queueGo            => l(:'ai_assistant.plan_queue_go'),
            :queueSkip          => l(:'ai_assistant.plan_queue_skip'),
            :queueCancel        => l(:'ai_assistant.plan_queue_cancel'),
            :queueDismiss       => l(:'ai_assistant.plan_queue_dismiss'),
            :queueDone          => l(:'ai_assistant.plan_queue_done'),
            :queueNoParent      => l(:'ai_assistant.plan_queue_no_parent'),
            :queueParentMissing => l(:'ai_assistant.plan_queue_parent_missing')
          },
          # Popisky polí berieme z JADROVÝCH prekladov Redmine — sú preložené do
          # všetkých jazykov a nemá zmysel ich duplikovať v plugine.
          :cancel        => l(:button_cancel),
          :labels        => {
            :project  => l(:field_project),
            :subject  => l(:field_subject),
            :tracker  => l(:field_tracker),
            :category => l(:field_category),
            :priority => l(:field_priority)
          }
        }
      }
    end
  end
end

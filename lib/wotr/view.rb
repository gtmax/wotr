# frozen_string_literal: true

require_relative 'version'

module Wotr
  class View
    SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'].freeze

    THEME = {
      header: { fg: :cyan, modifiers: [:bold] },
      border: { fg: '#555555' },
      selection: { fg: :black, bg: :cyan },
      text: { fg: :white },
      dim: { fg: '#888888' },
      accent: { fg: :cyan },
      dirty: { fg: :cyan },
      branch_diff: { fg: '#ff8c00' },
      clean: { fg: :green },
      modal_border: { fg: :magenta }
    }.freeze

    LOG_PANE_HEIGHT = 8

    def self.draw(model, tui, frame)
      app_width = [frame.area.width, 100].min
      msg_lines = wrap_text(model.message, app_width - 2).size
      legend_height = model.has_resources? ? 1 : 0
      actions_height = model.has_actions? ? 1 : 0
      footer_height = 1 + actions_height + legend_height + 1 + 1 + 1 + msg_lines  # keys + actions + legend + blank + dirty + status border + msg

      show_log = model.task_running?
      log_height = show_log ? LOG_PANE_HEIGHT : 0

      content_height = [model.visible_worktrees.size + 4 + footer_height + log_height, frame.area.height].min

      app_area = centered_app_area(tui, frame.area, width: 100, height: content_height)

      if show_log
        main_area, log_area, footer_area = tui.layout_split(
          app_area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(log_height),
            tui.constraint_length(footer_height)
          ]
        )
      else
        main_area, footer_area = tui.layout_split(
          app_area,
          direction: :vertical,
          constraints: [
            tui.constraint_fill(1),
            tui.constraint_length(footer_height)
          ]
        )
        log_area = nil
      end

      header_area, list_area = tui.layout_split(
        main_area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(2),
          tui.constraint_fill(1)
        ]
      )

      draw_header(tui, frame, header_area)
      draw_table(model, tui, frame, list_area)
      draw_log_pane(model, tui, frame, log_area) if log_area
      draw_footer(model, tui, frame, footer_area)
      update_mouse_areas(model, list_area, footer_area, msg_lines)

      return unless model.mode == :creating

      draw_input_modal(model, tui, frame)
    end

    def self.centered_app_area(tui, area, width:, height:)
      w = [area.width, width].min
      h = [[area.height, height].min, 15].max
      h = [h, area.height].min

      x = area.x + (area.width - w) / 2
      y = area.y + (area.height - h) / 2

      tui.rect(x: x, y: y, width: w, height: h)
    end

    def self.draw_header(tui, frame, area)
      title = tui.paragraph(
        text: [
          tui.text_line(spans: [
            tui.text_span(content: " 🌊 wotr v#{Wotr::VERSION} 🌊  ", style: tui.style(**THEME[:header])),
            tui.text_span(content: '"Be wotr, my friend!" — Bruce Lee ', style: tui.style(**THEME[:dim]))
          ])
        ],
        alignment: :center,
        block: tui.block(
          borders: [:bottom],
          border_style: tui.style(**THEME[:border])
        )
      )
      frame.render_widget(title, area)
    end

    def self.draw_table(model, tui, frame, area)
      show_icons = model.has_resources?

      rows = model.visible_worktrees.map do |wt|
        status_icon = wt.dirty ? '💧' : ' '
        status_style = wt.dirty ? tui.style(**THEME[:dirty]) : tui.style(**THEME[:clean])

        cells = [
          tui.table_cell(content: " #{status_icon} ", style: status_style),
          tui.table_cell(
            content: begin
                       spans = [
                         tui.text_span(content: "⑂ #{wt.branch || 'HEAD'}", style: tui.style(**THEME[:branch_diff]))
                       ]
                       unless wt.name == wt.branch || wt.branch.nil?
                         spans << tui.text_span(content: " @ #{wt.name}", style: tui.style(**THEME[:text]))
                       end
                       tui.text_line(spans: spans)
                     end
          ),
          tui.table_cell(
            content: tui.text_span(content: (wt.last_commit || ''), style: tui.style(**THEME[:accent]))
          )
        ]

        if show_icons
          icons_list = model.resource_icons_for(wt.path)
          content = ' ' + icons_list.map { |icon| "#{icon} " }.join
          # Pad the cell to its full constraint width so ratatui's background
          # fill never lands inside an emoji's second display column.
          # NOTE: Avoid emoji with U+FE0F (VS-16) in resource icons — they
          # cause rendering artifacts when ratatui's diff-based update applies
          # the row selection highlight. Use natively 2-wide emoji instead
          # (e.g. 💻 not 🖥️, 💾 not 🗄️).
          actual_width = RatatuiRuby._text_width(content)
          pad = [14 - actual_width, 0].max
          cells << tui.table_cell(content: content + ' ' * pad)
        end

        tui.row(cells: cells)
      end

      widths = [
        tui.constraint_length(3),
        tui.constraint_fill(1),
        tui.constraint_length(15)
      ]
      widths << tui.constraint_length(14) if show_icons

      # Dynamic Title based on context
      title_content = if model.mode == :filtering
                        tui.text_line(spans: [
                          tui.text_span(content: ' FILTERING: ', style: tui.style(**THEME[:accent])),
                          tui.text_span(content: model.filter_query,
                                        style: tui.style(
                                          fg: :white, modifiers: [:bold]
                                        ))
                        ])
                      else
                        tui.text_line(spans: [tui.text_span(content: ' WORKTREES ', style: tui.style(**THEME[:dim]))])
                      end

      header_cells = [
        tui.table_cell(content: '', style: tui.style(**THEME[:dim])),
        tui.table_cell(content: ' branch', style: tui.style(**THEME[:dim])),
        tui.table_cell(content: ' last commit', style: tui.style(**THEME[:dim]))
      ]
      header_cells << tui.table_cell(content: ' resources', style: tui.style(**THEME[:dim])) if show_icons

      table = tui.table(
        header: tui.row(cells: header_cells),
        rows: rows,
        widths: widths,
        selected_row: model.selection_index,
        highlight_symbol: '',
        row_highlight_style: tui.style(**THEME[:selection]),
        block: tui.block(
          titles: [{ content: title_content }],
          borders: [:all],
          border_style: tui.style(**THEME[:border])
        )
      )

      frame.render_widget(table, area)
    end

    def self.draw_footer(model, tui, frame, area)
      keys = []

      add_key = lambda { |key, desc|
        keys << tui.text_span(content: " #{key} ", style: tui.style(bg: :dark_gray, fg: :white))
        keys << tui.text_span(content: " #{desc} ", style: tui.style(**THEME[:dim]))
      }
      indent = tui.text_span(content: ' ', style: tui.style(**THEME[:text]))

      model.current_shortcuts.each { |s| add_key.call(s[:key], s[:desc]) }

      msg_style = if model.message.downcase.include?('error') || model.message.downcase.include?('warning')
                    tui.style(fg: :red, modifiers: [:bold])
                  else
                    tui.style(**THEME[:dim])
                  end

      text = [tui.text_line(spans: [indent] + keys)]

      if model.has_actions?
        action_spans = [indent]
        model.action_shortcuts.each do |key, name|
          action_spans << tui.text_span(content: " #{key} ", style: tui.style(bg: :dark_gray, fg: :white))
          action_spans << tui.text_span(content: " #{name} ", style: tui.style(**THEME[:dim]))
        end
        text = text + [tui.text_line(spans: action_spans)]
      end

      if model.has_resources?
        legend_spans = [indent]
        shortcuts = model.resource_shortcuts
        model.repository.config.resource_names.each do |name|
          icon = model.repository.config.resource(name)&.fetch('icon', '•') || '•'
          shortcut = shortcuts.key(name)
          legend_spans << tui.text_span(content: " #{shortcut} ", style: tui.style(bg: :dark_gray, fg: :white)) if shortcut
          legend_spans << tui.text_span(content: " #{icon} #{name} ", style: tui.style(**THEME[:dim]))
        end
        text = text + [tui.text_line(spans: legend_spans)]
      end

      text = text + [tui.text_line(spans: [])]

      dirty_line = tui.text_line(spans: [
        indent,
        tui.text_span(content: '💧', style: tui.style(**THEME[:dirty])),
        tui.text_span(content: ' uncommitted changes', style: tui.style(**THEME[:dim]))
      ])
      text = text + [dirty_line]

      # Split footer: top (keys + legend + dirty) and bottom (status message)
      msg_width = [area.width - 4, 1].max
      msg_lines = wrap_text(model.message, msg_width)
      status_height = 1 + msg_lines.size  # border + message lines

      top_area, status_area = tui.layout_split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(status_height)
        ]
      )

      footer = tui.paragraph(text: text)
      frame.render_widget(footer, top_area)

      status_text = msg_lines.map do |line|
        tui.text_line(spans: [indent, tui.text_span(content: line, style: msg_style)])
      end
      status_widget = tui.paragraph(
        text: status_text,
        block: tui.block(
          borders: [:top],
          border_style: tui.style(**THEME[:border])
        )
      )
      frame.render_widget(status_widget, status_area)

      # 2-row spinner at the far right, aligned with keys + legend rows
      return unless model.background_activity?

      n = (Time.now.to_f * 10).to_i
      top_char = SPINNER[n % SPINNER.length]
      bot_char = SPINNER[(n + SPINNER.length / 2) % SPINNER.length]

      sy = area.y  # no border, aligned with keys line
      sx = area.x + area.width - 2      # one col from the right edge

      spinner_widget = tui.paragraph(
        text: [
          tui.text_line(spans: [tui.text_span(content: top_char, style: tui.style(**THEME[:accent]))]),
          tui.text_line(spans: [tui.text_span(content: bot_char, style: tui.style(**THEME[:accent]))])
        ]
      )
      frame.render_widget(spinner_widget, tui.rect(x: sx, y: sy, width: 1, height: 2))
    end

    def self.draw_log_pane(model, tui, frame, area)
      # Show the last N lines that fit in the area (area height - 2 for borders)
      visible_lines = area.height - 2
      lines = model.task_log.last([visible_lines, 0].max)

      text = lines.map do |line|
        tui.text_line(spans: [
          tui.text_span(content: line, style: tui.style(**THEME[:dim]))
        ])
      end

      title = " #{model.task_label} "

      log_widget = tui.paragraph(
        text: text,
        block: tui.block(
          titles: [{
            content: tui.text_line(spans: [
              tui.text_span(content: title, style: tui.style(**THEME[:accent]))
            ])
          }],
          borders: [:all],
          border_style: tui.style(**THEME[:border])
        )
      )

      frame.render_widget(log_widget, area)
    end

    def self.draw_input_modal(model, tui, frame)
      area = center_rect(tui, frame.area, 50, 3)

      frame.render_widget(tui.clear, area)

      input = tui.paragraph(
        text: model.input_buffer,
        style: tui.style(fg: :white),
        block: tui.block(
          title: ' NEW SESSION ',
          title_style: tui.style(fg: :blue, modifiers: [:bold]),
          borders: [:all],
          border_style: tui.style(**THEME[:modal_border])
        )
      )

      frame.render_widget(input, area)
    end

    def self.wrap_text(text, width)
      return [] if text.empty?
      return [text] if text.length <= width

      lines = []
      current = ''
      text.split(' ').each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.length <= width
          current = candidate
        else
          lines << current unless current.empty?
          current = word
        end
      end
      lines << current unless current.empty?
      lines
    end

    def self.update_mouse_areas(model, list_area, footer_area, _msg_lines = 0)
      # List rows: inside the all-borders block, header at y+1, first data row at y+2
      list_top    = list_area.y + 2
      list_bottom = list_area.y + list_area.height - 2
      list_left   = list_area.x
      list_right  = list_area.x + list_area.width - 1

      # Footer: no border, content starts at y
      # Layout: [key line] [actions line?] [legend line?] [blank] [dirty] [status border + msg]
      key_y    = footer_area.y
      current_y = key_y + 1

      # Key shortcut buttons — ASCII only, so .length is accurate
      # +1 for the indent space prepended to the keys line
      x = footer_area.x + 1
      key_buttons = model.current_shortcuts.map do |shortcut|
        w = (shortcut[:key].length + 2) + (shortcut[:desc].length + 2)
        btn = { x_start: x, x_end: x + w - 1, key: shortcut[:key] }
        x += w
        btn
      end

      # Action buttons
      action_y = model.has_actions? ? current_y : nil
      action_buttons = []
      if model.has_actions?
        x = footer_area.x + 1
        model.action_shortcuts.each do |key, name|
          kw = key.length + 2
          dw = name.length + 2
          action_buttons << { x_start: x, x_end: x + kw + dw - 1, action: name }
          x += kw + dw
        end
        current_y += 1
      end

      # Resource legend buttons — use _text_width for emoji
      # +1 for the indent space prepended to the legend line
      legend_y = model.has_resources? ? current_y : nil
      legend_buttons = []
      if model.has_resources?
        x = footer_area.x + 1
        shortcuts = model.resource_shortcuts
        model.repository.config.resource_names.each do |name|
          icon = model.repository.config.resource(name)&.fetch('icon', '•') || '•'
          letter = shortcuts.key(name)
          if letter
            kw = RatatuiRuby._text_width(" #{letter} ")
            dw = RatatuiRuby._text_width(" #{icon} #{name} ")
            legend_buttons << { x_start: x, x_end: x + kw + dw - 1, resource: name }
            x += kw + dw
          else
            x += RatatuiRuby._text_width(" #{icon} #{name} ")
          end
        end
      end

      model.mouse_areas = {
        list_top: list_top, list_bottom: list_bottom,
        list_left: list_left, list_right: list_right,
        key_y: key_y, key_buttons: key_buttons,
        action_y: action_y, action_buttons: action_buttons,
        legend_y: legend_y, legend_buttons: legend_buttons
      }
    end

    def self.center_rect(tui, area, width_percent, height_len)
      vert = tui.layout_split(
        area,
        direction: :vertical,
        constraints: [
          tui.constraint_percentage((100 - 10) / 2),
          tui.constraint_length(height_len),
          tui.constraint_min(0)
        ]
      )

      horiz = tui.layout_split(
        vert[1],
        direction: :horizontal,
        constraints: [
          tui.constraint_percentage((100 - width_percent) / 2),
          tui.constraint_percentage(width_percent),
          tui.constraint_min(0)
        ]
      )

      horiz[1]
    end
  end
end

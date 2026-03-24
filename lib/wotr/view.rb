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

    LOG_MIN_HEIGHT = 4   # 2 content rows + 2 border rows
    LOG_RATIO = 0.30     # log gets 30% of space shared with list

    def self.draw(model, tui, frame)
      app_area = frame.area

      # Footer: compute how many lines all buttons need when flowing
      footer_height = compute_footer_height(model, app_area.width)

      # Compute log height: 30% of space shared with list, min 4 rows
      fixed_overhead = 1 + footer_height  # header + footer
      available = app_area.height - fixed_overhead
      log_height = [(available * LOG_RATIO).to_i, LOG_MIN_HEIGHT].max

      # Layout: header + table (fill), footer (fixed), log (proportional)
      main_area, footer_area, log_area = tui.layout_split(
        app_area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(footer_height),
          tui.constraint_length(log_height)
        ]
      )

      header_area, list_area = tui.layout_split(
        main_area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(1),
          tui.constraint_fill(1)
        ]
      )

      draw_header(tui, frame, header_area)
      draw_table(model, tui, frame, list_area)
      draw_footer(model, tui, frame, footer_area)
      draw_log_strip(model, tui, frame, log_area)
      update_mouse_areas(model, list_area, footer_area, log_area)

      return unless model.mode == :creating

      draw_input_modal(model, tui, frame)
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
          borders: [],
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

      title_content = if model.mode == :filtering
                        tui.text_line(spans: [
                          tui.text_span(content: ' FILTERING: ', style: tui.style(**THEME[:accent])),
                          tui.text_span(content: model.filter_query,
                                        style: tui.style(
                                          fg: :white, modifiers: [:bold]
                                        ))
                        ])
                      else
                        tui.text_line(spans: [tui.text_span(content: " Worktrees (#{model.worktrees.size}) ", style: tui.style(**THEME[:accent]))])
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

      # Dirty legend on the bottom border, right-aligned
      dirty_label = " 💧 uncommitted changes "
      dirty_w = RatatuiRuby._text_width(dirty_label)
      dx = area.x + area.width - dirty_w - 1
      dy = area.y + area.height - 1
      dirty_widget = tui.paragraph(
        text: [tui.text_line(spans: [
          tui.text_span(content: " 💧", style: tui.style(**THEME[:dirty])),
          tui.text_span(content: " uncommitted changes ", style: tui.style(**THEME[:dim]))
        ])]
      )
      frame.render_widget(dirty_widget, tui.rect(x: dx, y: dy, width: dirty_w, height: 1))
    end

    # Collect all footer buttons in order: built-in shortcuts, actions, resources
    def self.collect_footer_buttons(model)
      buttons = []

      model.current_shortcuts.each do |s|
        buttons << { key: s[:key], desc: s[:desc], type: :shortcut }
      end

      if model.has_actions?
        model.action_shortcuts.each do |key, name|
          buttons << { key: key, desc: name, type: :action, action: name }
        end
      end

      if model.has_resources?
        shortcuts = model.resource_shortcuts
        model.repository.config.resource_names.each do |name|
          icon = model.repository.config.resource(name)&.fetch('icon', '•') || '•'
          shortcut = shortcuts.key(name)
          next unless shortcut
          buttons << { key: shortcut, desc: "#{icon} #{name}", type: :resource, resource: name }
        end
      end

      buttons
    end

    def self.button_width(btn)
      key_w = btn[:key].length + 2  # " key "
      desc_w = if defined?(RatatuiRuby) && RatatuiRuby.respond_to?(:_text_width)
                 RatatuiRuby._text_width(" #{btn[:desc]} ")
               else
                 btn[:desc].length + 2
               end
      key_w + desc_w
    end

    def self.compute_footer_height(model, terminal_width)
      buttons = collect_footer_buttons(model)
      return 1 if buttons.empty?

      lines = 1
      x = 1
      buttons.each do |btn|
        w = button_width(btn)
        if x + w > terminal_width && x > 1
          lines += 1
          x = 1
        end
        x += w
      end
      lines
    end

    def self.draw_footer(model, tui, frame, area)
      buttons = collect_footer_buttons(model)
      width = area.width

      lines = []
      current_spans = [tui.text_span(content: ' ', style: tui.style(**THEME[:text]))]
      current_x = 1

      buttons.each do |btn|
        w = button_width(btn)
        if current_x + w > width && current_x > 1
          lines << tui.text_line(spans: current_spans)
          current_spans = [tui.text_span(content: ' ', style: tui.style(**THEME[:text]))]
          current_x = 1
        end
        current_spans << tui.text_span(content: " #{btn[:key]} ", style: tui.style(bg: :dark_gray, fg: :white))
        current_spans << tui.text_span(content: " #{btn[:desc]} ", style: tui.style(**THEME[:dim]))
        current_x += w
      end
      lines << tui.text_line(spans: current_spans) unless current_spans.size <= 1

      footer = tui.paragraph(text: lines)
      frame.render_widget(footer, area)
    end

    def self.draw_log_strip(model, tui, frame, area)
      visible_lines = area.height - 2  # subtract borders
      entries = model.visible_log_entries
      offset = model.log_scroll_offset

      # Slice the visible window from the log buffer
      end_idx = [entries.size - offset, 0].max
      start_idx = [end_idx - visible_lines, 0].max
      lines = entries[start_idx...end_idx] || []

      text = lines.flat_map do |entry|
        style = case entry[:style]
                when :error then tui.style(fg: :white, bg: :red, modifiers: [:bold])
                when :warn then tui.style(fg: :yellow)
                when :normal then tui.style(**THEME[:text])
                else tui.style(**THEME[:dim])
                end
        spans = [tui.text_span(content: " #{entry[:text]}", style: style)]

        result = []

        # For status entries with hidden output, show count + preview
        if !model.verbose && entry[:status] && (entry[:output_count] || 0) > 0
          spans << tui.text_span(content: "  (#{entry[:output_count]} lines)", style: tui.style(fg: '#555555'))
          result << tui.text_line(spans: spans)

          if entry[:last_output]
            preview = entry[:last_output].to_s
            max_w = area.width - 6
            preview = preview[0, max_w] if preview.length > max_w
            result << tui.text_line(spans: [
              tui.text_span(content: "  ↳ #{preview}", style: tui.style(fg: '#555555'))
            ])
          end
        else
          result << tui.text_line(spans: spans)
        end

        result
      end

      # Border title: task label (persists after completion), scroll indicator
      title_spans = []
      if model.task_label
        label_style = model.task_running? ? THEME[:accent] : THEME[:dim]
        title_spans << tui.text_span(content: " #{model.task_label} ", style: tui.style(**label_style))
      elsif offset > 0
        title_spans << tui.text_span(content: " log (scrolled ↑#{offset}) ", style: tui.style(**THEME[:accent]))
      end

      titles = title_spans.empty? ? [] : [{
        content: tui.text_line(spans: title_spans)
      }]

      border_style = if model.mode == :log_command
                       tui.style(**THEME[:accent])
                     else
                       tui.style(**THEME[:border])
                     end

      log_widget = tui.paragraph(
        text: text,
        block: tui.block(
          titles: titles,
          borders: [:all],
          border_style: border_style
        )
      )

      frame.render_widget(log_widget, area)

      # Log shortcuts on the bottom border, right-aligned
      draw_log_legend(model, tui, frame, area)

      # Double spinner inside the log pane, upper-right with margin
      if model.background_activity?
        n = (Time.now.to_f * 10).to_i
        top_char = SPINNER[n % SPINNER.length]
        bot_char = SPINNER[(n + SPINNER.length / 2) % SPINNER.length]
        sx = area.x + area.width - 3
        sy = area.y + 1

        spinner_widget = tui.paragraph(
          text: [
            tui.text_line(spans: [tui.text_span(content: top_char, style: tui.style(**THEME[:accent]))]),
            tui.text_line(spans: [tui.text_span(content: bot_char, style: tui.style(**THEME[:accent]))])
          ]
        )
        frame.render_widget(spinner_widget, tui.rect(x: sx, y: sy, width: 1, height: 2))
      end
    end

    def self.draw_log_legend(model, tui, frame, area)
      in_chord = model.mode == :log_command
      l_style = in_chord ? tui.style(bg: :cyan, fg: :black) : tui.style(bg: :dark_gray, fg: :white)
      second_key_style = in_chord ? tui.style(bg: :dark_gray, fg: :white) : tui.style(**THEME[:dim])
      label_style = tui.style(**THEME[:dim])
      mode_label = model.verbose ? "verbose" : "compact"

      spans = [
        tui.text_span(content: " ", style: label_style),
        tui.text_span(content: "l", style: l_style),
        tui.text_span(content: "v", style: second_key_style),
        tui.text_span(content: " current log mode: #{mode_label} ", style: label_style),
        tui.text_span(content: "l", style: l_style),
        tui.text_span(content: "c", style: second_key_style),
        tui.text_span(content: " copy log to clipboard ", style: label_style),
        tui.text_span(content: "l", style: l_style),
        tui.text_span(content: "p", style: second_key_style),
        tui.text_span(content: " copy logfile path to clipboard ", style: label_style)
      ]

      total_w = " lv current log mode: #{mode_label} lc copy log to clipboard lp copy logfile path to clipboard ".length + 1

      cx = area.x + area.width - total_w - 1
      cy = area.y + area.height - 1

      legend_widget = tui.paragraph(
        text: [tui.text_line(spans: spans)]
      )
      frame.render_widget(legend_widget, tui.rect(x: cx, y: cy, width: total_w, height: 1))
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

    def self.update_mouse_areas(model, list_area, footer_area, log_area)
      # List rows: inside the all-borders block, header at y+1, first data row at y+2
      list_top    = list_area.y + 2
      list_bottom = list_area.y + list_area.height - 2
      list_left   = list_area.x
      list_right  = list_area.x + list_area.width - 1

      # Footer buttons — flow with wrapping, matching draw_footer layout
      buttons = collect_footer_buttons(model)
      width = footer_area.width
      footer_buttons = []
      fx = footer_area.x + 1
      fy = footer_area.y

      buttons.each do |btn|
        w = button_width(btn)
        if fx + w > footer_area.x + width && fx > footer_area.x + 1
          fy += 1
          fx = footer_area.x + 1
        end
        cmd = case btn[:type]
              when :shortcut  then { type: :shortcut, key: btn[:key] }
              when :action    then { type: :run_action, name: btn[:action] }
              when :resource  then { type: :acquire_resource, name: btn[:resource] }
              end
        footer_buttons << { x_start: fx, x_end: fx + w - 1, y: fy, cmd: cmd }
        fx += w
      end

      # Log legend buttons on bottom border
      log_bottom_y = log_area.y + log_area.height - 1
      mode_label = model.verbose ? "verbose" : "compact"
      log_legend_w = " lv current log mode: #{mode_label} lc copy log to clipboard lp copy logfile path to clipboard ".length + 1
      log_legend_x_start = log_area.x + log_area.width - log_legend_w - 1

      lv_start = log_legend_x_start
      lv_end = lv_start + " lv current log mode: #{mode_label} ".length
      lc_start = lv_end + 1
      lc_end = lc_start + "lc copy log to clipboard ".length - 1
      lp_start = lc_end + 1
      lp_end = lp_start + "lp copy logfile path to clipboard ".length - 1

      model.mouse_areas = {
        list_top: list_top, list_bottom: list_bottom,
        list_left: list_left, list_right: list_right,
        footer_buttons: footer_buttons,
        log_top: log_area.y,
        log_bottom_y: log_bottom_y,
        log_buttons: [
          { x_start: lv_start, x_end: lv_end, cmd: :toggle_verbose },
          { x_start: lc_start, x_end: lc_end, cmd: :copy_log },
          { x_start: lp_start, x_end: lp_end, cmd: :copy_log_path }
        ]
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

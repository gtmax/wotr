# frozen_string_literal: true

require_relative 'version'

module Wotr
  class View
    THEME = {
      header: { fg: :blue, modifiers: [:bold] },
      border: { fg: :dark_gray },
      selection: { fg: :black, bg: :blue },
      text: { fg: :white },
      dim: { fg: :dark_gray },
      accent: { fg: :cyan },
      dirty: { fg: :yellow },
      clean: { fg: :green },
      modal_border: { fg: :magenta }
    }.freeze

    def self.draw(model, tui, frame)
      content_height = [model.visible_worktrees.size + 6, frame.area.height].min

      app_area = centered_app_area(tui, frame.area, width: 100, height: content_height)

      main_area, footer_area = tui.layout_split(
        app_area,
        direction: :vertical,
        constraints: [
          tui.constraint_fill(1),
          tui.constraint_length(3)
        ]
      )

      header_area, list_area = tui.layout_split(
        main_area,
        direction: :vertical,
        constraints: [
          tui.constraint_length(3),
          tui.constraint_fill(1)
        ]
      )

      draw_header(tui, frame, header_area)
      draw_table(model, tui, frame, list_area)
      draw_footer(model, tui, frame, footer_area)

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
        text: " WOTR v#{Wotr::VERSION} • WORKTREE MANAGER ",
        alignment: :center,
        style: tui.style(**THEME[:header]),
        block: tui.block(
          borders: [:bottom],
          border_style: tui.style(**THEME[:border])
        )
      )
      frame.render_widget(title, area)
    end

    def self.draw_table(model, tui, frame, area)
      rows = model.visible_worktrees.map do |wt|
        status_icon = wt.dirty ? '●' : ' '
        status_style = wt.dirty ? tui.style(**THEME[:dirty]) : tui.style(**THEME[:clean])

        tui.row(cells: [
          tui.table_cell(content: " #{status_icon} ", style: status_style),
          tui.table_cell(
            content: tui.text_span(content: wt.name, style: tui.style(modifiers: [:bold]))
          ),
          tui.table_cell(
            content: tui.text_span(content: wt.branch || 'HEAD', style: tui.style(**THEME[:dim]))
          ),
          tui.table_cell(
            content: tui.text_span(content: (wt.last_commit || ''), style: tui.style(**THEME[:accent]))
          )
        ])
      end

      widths = [
        tui.constraint_length(3),
        tui.constraint_fill(1),
        tui.constraint_fill(1),
        tui.constraint_length(15)
      ]

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
                        tui.text_line(spans: [tui.text_span(content: ' SESSIONS ', style: tui.style(**THEME[:dim]))])
                      end

      table = tui.table(
        rows: rows,
        widths: widths,
        selected_row: model.selection_index,
        row_highlight_style: tui.style(**THEME[:selection]),
        highlight_symbol: '▎',
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

      case model.mode
      when :creating
        add_key.call('Enter', 'Confirm')
        add_key.call('Esc', 'Cancel')
      when :filtering
        add_key.call('Type', 'Search')
        add_key.call('Enter', 'CD')
        add_key.call('Esc', 'Reset')
      else
        add_key.call('n', 'New')
        add_key.call('/', 'Filter')
        add_key.call('Enter', 'CD')
        add_key.call('s', 'Switch')
        add_key.call('r', 'Resume')
        add_key.call('d', 'Delete')
        add_key.call('Esc', 'Quit')
      end

      msg_style = if model.message.downcase.include?('error') || model.message.downcase.include?('warning')
                    tui.style(fg: :red, modifiers: [:bold])
                  else
                    tui.style(**THEME[:accent])
                  end

      text = [
        tui.text_line(spans: [tui.text_span(content: model.message, style: msg_style)]),
        tui.text_line(spans: keys)
      ]

      footer = tui.paragraph(
        text: text,
        block: tui.block(
          borders: [:top],
          border_style: tui.style(**THEME[:border])
        )
      )

      frame.render_widget(footer, area)
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

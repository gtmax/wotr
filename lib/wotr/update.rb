# frozen_string_literal: true

module Wotr
  class Update
    def self.handle(model, message)
      case message[:type]
      when :tick
        nil
      when :quit
        model.quit
      when :key_press
        handle_key(model, message[:key])
      when :paste
        handle_paste(model, message[:content])
      when :refresh_list
        refresh_list(model)
        :start_background_fetch
      when :delete_worktree
        worktree = message[:worktree]
        force = message[:force] || false

        result = worktree.delete!(force: force)

        if result[:success]
          if result[:warning]
            model.set_message("Warning: #{result[:warning]}. Use 'D' to force delete.")
          else
            model.set_message("Deleted worktree #{worktree.branch || worktree.name}.")
          end
          refresh_list(model)
          :start_background_fetch
        else
          model.set_message("Error deleting: #{result[:error]}. Use 'D' to force delete.")
          nil
        end
      when :update_status
        return nil if message[:generation] != model.fetch_generation

        target = model.find_worktree_by_path(message[:path])
        target.dirty = message[:status][:dirty] if target
        nil
      when :update_commit_age
        return nil if message[:generation] != model.fetch_generation

        target = model.find_worktree_by_path(message[:path])
        target.last_commit = message[:age] if target
        nil
      when :update_resource_icons
        model.update_resource_icons(message[:icons_by_path])
        model.finish_background_activity
        nil
      end
    end

    def self.handle_key(model, event)
      if model.mode == :creating
        if event.enter?
          return { type: :create_worktree, name: model.input_buffer }
        elsif event.esc?
          model.set_mode(:normal)
        elsif event.backspace?
          model.input_backspace
        elsif event.to_s.length == 1
          model.input_append(event.to_s)
        end
      elsif model.mode == :filtering
        if event.enter?
          wt = model.selected_worktree
          if wt
            model.set_filter(String.new) # Clear filter
            model.set_mode(:normal) # Exit filter mode on selection
            return { type: :resume_worktree, worktree: wt }
          else
            model.set_mode(:normal)
          end
        elsif event.esc?
          model.set_filter(String.new) # Clear filter
          model.set_mode(:normal)
        elsif event.backspace?
          model.input_backspace
        elsif event.down? || event.ctrl_n?
          model.move_selection(1)
        elsif event.up? || event.ctrl_p?
          model.move_selection(-1)
        elsif event.to_s.length == 1
          model.input_append(event.to_s)
        end
      elsif model.mode == :log_command
        # Second key of "l" chord
        cmd = case event.to_s
              when 'c' then { type: :copy_log }
              when 'v' then { type: :toggle_verbose }
              when 'p' then { type: :copy_log_path }
              end
        model.set_mode(:normal)
        return cmd
      else
        # Normal Mode
        if event.q? || event.ctrl_c? || event.esc?
          return { type: :quit }
        elsif event.j? || event.down?
          model.move_selection(1)
        elsif event.k? || event.up?
          model.move_selection(-1)
        elsif event.n?
          model.set_mode(:creating)
        elsif event.slash? # / key
          model.set_mode(:filtering)
        elsif event.d?
          wt = model.selected_worktree
          return { type: :delete_worktree, worktree: wt, force: false } if wt
        elsif event.D? # Shift+d
          wt = model.selected_worktree
          return { type: :delete_worktree, worktree: wt, force: true } if wt
        elsif event.enter?
          wt = model.selected_worktree
          return { type: :resume_worktree, worktree: wt } if wt
        elsif event.s?
          wt = model.selected_worktree
          return { type: :cd_worktree, worktree: wt } if wt
        elsif event.l?
          model.set_mode(:log_command)
        elsif event.R? # Shift+r
          return { type: :refresh_list }
        elsif (resource_name = model.resource_shortcuts[event.to_s])
          wt = model.selected_worktree
          return { type: :acquire_resource, name: resource_name, worktree: wt } if wt
        elsif (action_name = model.action_shortcuts[event.to_s])
          wt = model.selected_worktree
          return { type: :run_action, name: action_name, worktree: wt } if wt
        end
      end
      nil
    end

    def self.handle_mouse(model, event)
      areas = model.mouse_areas
      return nil if areas.empty?

      # Scroll wheel → log strip or worktree list depending on position
      if event.scroll_up?
        if areas[:log_top] && event.y >= areas[:log_top]
          model.log_scroll_up
        else
          model.move_selection(-1)
        end
        return nil
      elsif event.scroll_down?
        if areas[:log_top] && event.y >= areas[:log_top]
          model.log_scroll_down
        else
          model.move_selection(1)
        end
        return nil
      end

      return nil unless event.down?

      x, y = event.x, event.y

      # Row click
      if y >= areas[:list_top] && y <= areas[:list_bottom] &&
         x >= areas[:list_left] && x <= areas[:list_right]
        row = y - areas[:list_top]
        list = model.visible_worktrees
        if row >= 0 && row < list.size
          if model.selection_index == row && model.mode == :normal
            wt = list[row]
            return { type: :resume_worktree, worktree: wt } if wt
          else
            model.selection_index = row
          end
        end
        return nil
      end

      # Footer button clicks (unified: shortcuts, actions, resources)
      if areas[:footer_buttons]
        areas[:footer_buttons].each do |btn|
          next unless y == btn[:y] && x >= btn[:x_start] && x <= btn[:x_end]
          cmd = btn[:cmd]
          case cmd[:type]
          when :shortcut
            return trigger_shortcut(model, cmd[:key])
          when :run_action
            wt = model.selected_worktree
            return { type: :run_action, name: cmd[:name], worktree: wt } if wt
          when :acquire_resource
            wt = model.selected_worktree
            return { type: :acquire_resource, name: cmd[:name], worktree: wt } if wt
          end
        end
      end

      # Log legend button clicks
      if areas[:log_bottom_y] && y == areas[:log_bottom_y] && areas[:log_buttons]
        areas[:log_buttons].each do |btn|
          next unless x >= btn[:x_start] && x <= btn[:x_end]
          return { type: btn[:cmd] }
        end
      end

      # Click inside log pane content → copy log to clipboard
      if areas[:log_top] && areas[:log_bottom_y] &&
         y > areas[:log_top] && y < areas[:log_bottom_y]
        return { type: :copy_log }
      end

      nil
    end

    def self.trigger_shortcut(model, key)
      case model.mode
      when :normal
        case key
        when 'n'     then model.set_mode(:creating)
        when '/'     then model.set_mode(:filtering)
        when 'Enter'
          wt = model.selected_worktree
          return { type: :resume_worktree, worktree: wt } if wt
        when 's'
          wt = model.selected_worktree
          return { type: :cd_worktree, worktree: wt } if wt
        when 'd'
          wt = model.selected_worktree
          return { type: :delete_worktree, worktree: wt, force: false } if wt
        when 'Esc'
          return { type: :quit }
        end
      when :creating
        case key
        when 'Enter' then return { type: :create_worktree, name: model.input_buffer }
        when 'Esc'   then model.set_mode(:normal)
        end
      when :filtering
        case key
        when 'Enter'
          wt = model.selected_worktree
          if wt
            model.set_filter(String.new)
            model.set_mode(:normal)
            return { type: :resume_worktree, worktree: wt }
          else
            model.set_mode(:normal)
          end
        when 'Esc'
          model.set_filter(String.new)
          model.set_mode(:normal)
        end
      end
      nil
    end

    def self.handle_paste(model, content)
      return nil unless model.mode == :creating || model.mode == :filtering

      # Use first line only, strip whitespace
      text = content.split("\n", 2).first.to_s.strip
      model.input_append(text)
      nil
    end

    def self.refresh_list(model)
      Git.prune_worktrees(git: model.repository.git)
      model.refresh_worktrees!
    end
  end
end

-- One-off migration tool: replaces standalone "2px" values with
-- var(--base-spacing) across .vue/.ts/.scss files in the cwd.
vim.api.nvim_create_user_command("Replace2px", function()
  local cwd = vim.uv.cwd()
  local log_path = cwd .. "/replace2px-debug.txt"
  local debug_lines = {}

  local find_cmd = [[
    find . -type f \( -name '*.vue' -o -name '*.ts' -o -name '*.scss' \) \
    -not -path './node_modules/*' -not -path './dist/*' -not -path './.git/*'
  ]]

  local files = vim.fn.systemlist(find_cmd)

  if vim.tbl_isempty(files) then
    print("No matching files found.")
    return
  end

  table.insert(debug_lines, "Files found:\n" .. table.concat(files, "\n") .. "\n")

  local changed_files = {}

  for _, file in ipairs(files) do
    local ok = pcall(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(file))

      local changed = vim.api.nvim_buf_call(0, function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        local new_lines = {}
        local replaced = false

        for _, line in ipairs(lines) do
          local newline = line
          -- Match only exact "2px", avoid 12px etc., but allow in calc() and !important
          local n1
          newline, n1 = newline:gsub('([^%d])2px(%s*!?)', '%1var(--base-spacing)%2')
          local n2
          newline, n2 = newline:gsub('(^%s*[^%d:]*)2px(%s*!?)', '%1var(--base-spacing)%2')
          if n1 > 0 or n2 > 0 then replaced = true end
          table.insert(new_lines, newline)
        end

        if replaced then
          vim.api.nvim_buf_set_lines(0, 0, -1, false, new_lines)
          vim.cmd('write')
        end

        return replaced
      end)

      if changed then
        table.insert(changed_files, file)
      end

      vim.cmd('bdelete!')
    end)

    if not ok then
      table.insert(debug_lines, "❌ Failed to process file: " .. file)
    end
  end

  table.insert(debug_lines, "\nFiles changed:\n" .. table.concat(changed_files, "\n") .. "\n")

  local fd = io.open(log_path, "w")
  if fd then
    fd:write(table.concat(debug_lines, "\n"))
    fd:close()
    print("✅ Replace2px done. Debug log saved to " .. log_path)
  else
    print("⚠️ Could not write debug log to " .. log_path)
  end
end, {})

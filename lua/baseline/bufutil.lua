-- Small buffer helpers shared by the file-tree open action and the follower, so
-- that "browsing" files (clicking around the tree, or the viewer following
-- Claude's edits) doesn't pile up buffers in the tabline.

local M = {}

-- A buffer is safe to wipe when it is an unmodified, listed, normal file that is
-- no longer displayed in any window. This deliberately spares modified buffers,
-- terminals, the tree, help/quickfix, and [No Name] scratch buffers.
function M.is_wipeable(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  if vim.bo[buf].modified or vim.bo[buf].buftype ~= '' or not vim.bo[buf].buflisted then
    return false
  end
  if vim.bo[buf].filetype == 'NvimTree' or vim.api.nvim_buf_get_name(buf) == '' then
    return false
  end
  return #vim.fn.win_findbuf(buf) == 0
end

-- Wipe `buf` if it is no longer needed (see is_wipeable). Safe to call always.
function M.wipe_if_unused(buf)
  if M.is_wipeable(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = false })
  end
end

return M

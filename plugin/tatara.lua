-- SPDX-FileCopyrightText: 2026 PangMo5 and contributors
-- SPDX-License-Identifier: AGPL-3.0-only

if vim.g.loaded_tatara then
  return
end
vim.g.loaded_tatara = true
vim.api.nvim_create_autocmd('SessionLoadPost', {
  group = vim.api.nvim_create_augroup('TataraSessionRestore', { clear = true }),
  callback = function()
    vim.schedule(function()
      require('tatara').prune_restored()
    end)
  end,
})
vim.api.nvim_create_user_command('Tatara', function(args)
  require('tatara').command(args)
end, {
  nargs = '*',
  range = true,
  complete = function()
    return {
      'list',
      'issues',
      'close',
      'files',
      'overview',
      'diff_view',
      'checks',
      'combined',
      'discussion',
      'comments',
      'comment',
      'file_comment',
      'post_comment',
      'review',
      'drafts',
      'filters',
      'find_files',
      'grep',
      'mark_reviewed',
      'mark_hunk_reviewed',
      'toggle_reviewed',
      'filter_files',
      'saved_reviews',
      'suggest',
      'typed_comment',
      'export',
      'browser',
      'help',
      'theme',
      'notifications',
      'refresh',
    }
  end,
  desc = 'Review a pull request with native Neovim buffers',
})

return {
  -- Sync files to/from a remote over SSH/rsync (:TransferUpload / :TransferDownload)
  {
    'coffebar/transfer.nvim',
    lazy = true,
    cmd = {
      'TransferInit',
      'DiffRemote',
      'TransferUpload',
      'TransferDownload',
      'TransferDirDiff',
      'TransferRepeat',
    },
    opts = {},
  },
}

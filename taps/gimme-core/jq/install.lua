function install(ctx)
  local asset = ctx:download()
  -- jq ships as a raw binary, not an archive. Copy it directly.
  ctx:install_dir(asset)
  -- Rename: the asset file is named "jq-macos-arm64" but provides "jq"
  ctx:set_provides({"jq"})
end

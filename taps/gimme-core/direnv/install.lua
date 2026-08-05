function install(ctx)
  local asset = ctx:download()
  ctx:install_dir(asset)
  ctx:set_provides({"direnv"})
end

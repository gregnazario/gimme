function install(ctx)
  local host = ctx:host()
  local asset = ctx:download()
  local dir = ctx:extract(asset)
  -- install_dir moves the given directory's contents into the prefix.
  -- The tarball contains payload/{bin,share}; install payload so bin/ lands
  -- at $prefix/bin/.
  ctx:install_dir(dir .. "/payload")
  ctx:set_provides({"hello"})
  ctx:mkdir("${prefix}/share/man")
end

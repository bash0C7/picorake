MRuby::Gem::Specification.new('picorake-bin') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'picorake command'

  spec.add_dependency 'mruby-compiler'
  spec.add_dependency 'picoruby-mruby'
  spec.add_dependency 'mruby-io', gemdir: "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-io"
  spec.add_dependency 'mruby-file-stat', gemdir: "#{MRUBY_ROOT}/mrbgems/mruby-file-stat"
  spec.add_dependency 'picoruby-env'
  spec.add_dependency 'picoruby-require'
  spec.add_dependency 'picorake'
  spec.add_dependency 'picorake-spawn'

  build.bins << 'picorake'

  picorake_src = "#{dir}/tools/picorake/picorake.c"
  bin_obj = objfile(picorake_src.pathmap("#{build_dir}/tools/picorake/%n"))

  file bin_obj => ["#{MRUBY_ROOT}/include/picoruby.h", picorake_src] do |f|
    cc.run bin_obj, picorake_src
  end

  file exefile("#{build.build_dir}/bin/picorake") => [bin_obj, build.libmruby_static] do |f|
    build.linker.run f.name, f.prerequisites
  end
end

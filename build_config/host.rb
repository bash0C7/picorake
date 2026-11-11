MRuby::Build.new do |conf|
  conf.toolchain :gcc

  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_DEBUG"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"
  conf.cc.defines << "HEAP_SIZE=#{64 * 1024 * 1024}"

  conf.picoruby

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gem core: 'picoruby-bin-picoruby'
  conf.gem core: 'picoruby-picotest'

  Dir.glob(File.expand_path("../mrbgems/*/mrbgem.rake", __dir__)).sort.each do |rake|
    conf.gem gemdir: File.dirname(rake)
  end
end

# Implementation-specific behavior for Kernel#require and Kernel#load.
#
# In particular, this file implements #load_file for loading a Ruby source
# file and #load_library for loading a shared library extension file.
#
# Also provides #require_compiled which loads a precompiled version of a Ruby
# source file. Several CodeLoader class methods are implemented as a
# convenient way to invoke the CodeLoader.

module Rubinius
  class InvalidRBC < RuntimeError; end

  class CodeLoader

    # Loads compiled files. Performs exactly as Kernel#require except that
    #
    #   require "some_file"
    #
    # will resolve to "some_file.rbc" on the $LOAD_PATH, rather than
    # "some_file.rb".
    #
    # However, if "some_file.rbc" does not exist, then like #require, this
    # method will search for a shared library extension file to load using the
    # platform's file extension for shared libraries. This simplifies loading
    # a set of pre-compiled .rbc files that also may load an extension as in
    # the case of loading the compiler on bootstrap.
    def require_compiled(check_version=true)
      saved_check = CodeLoader.check_version
      saved_extension = CodeLoader.source_extension

      CodeLoader.load_compiled = true
      CodeLoader.check_version = check_version
      CodeLoader.source_extension = ".rbc"

      req = self.require

      Rubinius.run_script self.compiled_code

      CodeLoader.loaded_hook.trigger!(@path)

      add_feature

      return true
    ensure
      req.remove! if req

      CodeLoader.check_version = saved_check
      CodeLoader.source_extension = saved_extension
      CodeLoader.load_compiled = false
    end

    # Loads a Ruby source file specified on the command line. There is no
    # search required as the path on the command line must directly refernce a
    # loadable file. Also, the value of __FILE__ in a script loaded on the
    # command line differs from the value in a file loaded by Kernel#require
    # or Kernel#load.
    def load_script(debug)
      @file_path = @path
      @load_path = File.expand_path @path

      load_error unless loadable? @load_path
      script = load_file

      script.make_main!

      Rubinius.run_script self.compiled_code

      CodeLoader.loaded_hook.trigger!(@path)
    end

    # Overrides the version of #add_feature provided in kernel/common. When
    # loading precompiled source files via #require, adds ".rb" files to
    # $LOADED_FEATURES.
    def add_feature
      name = @feature.suffix?(".rbc") ? @feature[0..-2] : @feature
      $LOADED_FEATURES << name
      add_feature_to_index(feature)
    end

    # Default check_version flag to true
    @check_version = true

    class << self
      attr_accessor :load_compiled
      attr_accessor :check_version

      # Requires pre-installed gems directly to prevent Bundler and RubyGems
      # from disabling the gems and to permit bootstrapping RubyGems.
      #
      # TODO: Patch Bundler to recognize pre-installed gems when resolving
      # dependencies and fix RubyGems hijacking #require.
      def rubygems_require(name)
        @rubygems_dirs ||= Dir["#{Rubinius::GEMS_PATH}/gems/**/lib"]

        lib_name = name.end_with?(".rb") ? name : name + ".rb"

        @rubygems_dirs.each_with_index do |dir, index|
          if dir and File.exist? "#{dir}/#{lib_name}"
            $LOAD_PATH.unshift dir
            @rubygems_dirs[index] = nil

            return require(name)
          end
        end

        return false
      end

      # Loads rubygems using the bootstrap standard library files.
      def load_rubygems
        require "rubygems"
      end

      # Loads the pre-compiled bytecode compiler. Sets up paths needed by the
      # compiler to find dependencies like the parser.
      def load_compiler
        begin
          Dir["#{Rubinius::RUNTIME_PATH}/gems/**/lib"].each do |dir|
            $LOAD_PATH.unshift dir
          end

          require_compiled "rubinius/toolset"

          Rubinius::ToolSet.start
          require_compiled "rubinius/melbourne"
          require_compiled "rubinius/processor"
          require_compiled "rubinius/compiler"
          require_compiled "rubinius/ast"
          Rubinius::ToolSet.finish :runtime
        rescue Object => e
          raise LoadError, "Unable to load the bytecode compiler", e
        end
      end

      def require_compiled(name, check_version=true)
        new(name).require_compiled(check_version)
      end

      def load_script(name, debug=false)
        new(name).load_script(debug)
      end

      def execute_script(script)
        eval(script, TOPLEVEL_BINDING)
      end

      def save_compiled?
        @save_compiled ||= Config["compiler.no_rbc"] == nil
      end
    end

    # Given a path to a Ruby source file to load (i.e. @load_path), determines
    # whether a compiled version exists and is up-to-date. If it is, loads the
    # compiled version. Otherwise, compiles the Ruby source file.
    #
    # TODO: Make the compiled version checking logic available as a Compiler
    # convenience method.
    def load_file(wrap=false)
      signature = CodeLoader.check_version ? Signature : 0
      version = Rubinius::RUBY_LIB_VERSION

      if CodeLoader.load_compiled
        code = load_compiled_file @load_path, signature, version
      else
        c = Rubinius::ToolSet::Runtime::Compiler
        compiled_name = c.compiled_name @load_path

        if compiled_name
          begin
            compiled_stat = File::Stat.stat compiled_name

            if compiled_stat and @stat.mtime >= compiled_stat.mtime
              code = compile_file @load_path, compiled_name
            else
              begin
                code = load_compiled_file compiled_name, signature, version
              rescue TypeError, InvalidRBC
                code = compile_file @load_path, compiled_name
              end
            end
          rescue Errno::ENOENT
            code = compile_file @load_path, compiled_name
          end
        else
          code = compile_file @load_path, compiled_name
        end
      end

      script = code.create_script(wrap)
      script.file_path = @file_path
      script.data_path = @load_path

      @compiled_code = code
      CodeLoader.compiled_hook.trigger! script
      return script
    end

    attr_reader :compiled_code

    # Compile a Ruby source file and save the compiled file. Return the
    # internal representation (CompiledCode) of the Ruby source file.
    def compile_file(file, compiled)
      c = Rubinius::ToolSet::Runtime::Compiler
      if CodeLoader.save_compiled?
        c.compile file, compiled
      else
        c.compile_file file
      end
    end

    # Load a compiled version of a Ruby source file.
    def load_compiled_file(path, signature, version)
      Rubinius.primitive :compiledfile_load

      raise InvalidRBC, path
    end

    # Load a shared library extension file.
    def load_library
      name = File.basename @load_path, LIBSUFFIX

      NativeMethod.load_extension(@load_path, name)
    end
  end
end

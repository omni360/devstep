require 'language_pack/ruby'

# Force our custom metadata dir to be used
DEVSTEP_METADATA = "#{ENV['HOME']}/.metadata"
LanguagePack::Metadata.send(:remove_const, :FOLDER)
LanguagePack::Metadata.const_set(:FOLDER, LanguagePack::RubyDev::DEVSTEP_METADATA)

class LanguagePack::RubyDev < LanguagePack::Ruby
  def initialize(build_path, cache_path=nil)
    # Prevent metadata object from using the cache by forcing a nil here
    super(build_path, nil)
    # TODO: Find out how can we use the cache for rubies
  end

  def compile
    instrument 'ruby_dev.compile' do
      # check for new app at the beginning of the compile
      new_app?
      Dir.chdir(build_path)
      # remove_vendor_bundle
      install_ruby
      install_jvm
      setup_language_pack_environment
      setup_profiled
      allow_git do
        install_bundler_in_app
        build_bundler
        # create_database_yml
        # install_binaries
        # run_assets_precompile_rake_task
      end
      # We can't call super here...
      # super
    end

    # ... so we somehow mimic its behavior over here
    instrument 'base.compile' do
      Kernel.puts ""
      @warnings.each do |warning|
        Kernel.puts "###### WARNING:"
        puts warning
        Kernel.puts ""
      end
      if @deprecations.any?
        topic "DEPRECATIONS:"
        puts @deprecations.join("\n")
      end
    end
  end

private

  def add_to_profiled(string)
    FileUtils.mkdir_p "#{ENV['HOME']}/.profile.d"
    File.open("#{ENV['HOME']}/.profile.d/ruby.sh", "a") do |file|
      file.puts string
    end
  end

  # the base PATH environment variable to be used
  # @return [String] the resulting PATH
  def default_path
    # need to remove bin/ folder since it links
    # to the wrong --prefix ruby binstubs
    # breaking require. This only applies to Ruby 1.9.2 and 1.8.7.
    safe_binstubs = binstubs_relative_paths - ["bin"]
    paths         = [
      ENV["PATH"],
      "bin",
      system_paths,
    ]
    paths.unshift("#{slug_vendor_jvm}/bin") if ruby_version.jruby?
    paths.unshift(safe_binstubs)

    paths.join(":")
  end

  def binstubs_relative_paths
    [
      "bin",
      bundler_binstubs_path,
      "#{slug_vendor_base}/bin"
    ]
  end

  def system_paths
    "/usr/local/bin:/usr/bin:/bin"
  end

  # the relative path to the bundler directory of gems
  # @return [String] resulting path
  def slug_vendor_base
    instrument 'ruby_dev.slug_vendor_base' do
      if @slug_vendor_base
        @slug_vendor_base
      elsif ruby_version.ruby_version == "1.8.7"
        @slug_vendor_base = "vendor/bundle/1.8"
      else
        @slug_vendor_base = run_no_pipe(%q(ruby -e "require 'rbconfig';puts \"vendor/bundle/#{RUBY_ENGINE}/#{RbConfig::CONFIG['ruby_version']}\"")).chomp
        error "Problem detecting bundler vendor directory: #{@slug_vendor_base}" unless $?.success?
        @slug_vendor_base
      end
    end
  end

  # the relative path to the vendored ruby directory
  # @return [String] resulting path
  def slug_vendor_ruby
    "vendor/#{ruby_version.version_without_patchlevel}"
  end

  # the relative path to the vendored jvm
  # @return [String] resulting path
  def slug_vendor_jvm
    "vendor/jvm"
  end

  # the absolute path of the build ruby to use during the buildpack
  # @return [String] resulting path
  def build_ruby_path
    "/tmp/#{ruby_version.version_without_patchlevel}"
  end

  # fetch the ruby version from bundler
  # @return [String, nil] returns the ruby version if detected or nil if none is detected
  def ruby_version
    instrument 'ruby_dev.ruby_version' do
      return @ruby_version if @ruby_version
      new_app           = !File.exist?("vendor/heroku")
      last_version_file = "buildpack_ruby_version"
      last_version      = nil
      last_version      = @metadata.read(last_version_file).chomp if @metadata.exists?(last_version_file)

      @ruby_version = LanguagePack::RubyVersion.new(bundler.ruby_version,
        is_new:       new_app,
        last_version: last_version)
      return @ruby_version
    end
  end

  # default JAVA_OPTS
  # return [String] string of JAVA_OPTS
  def default_java_opts
    "-Xmx384m -Xss512k -XX:+UseCompressedOops -Dfile.encoding=UTF-8"
  end

  # default JRUBY_OPTS
  # return [String] string of JRUBY_OPTS
  def default_jruby_opts
    "-Xcompile.invokedynamic=false"
  end

  # default JAVA_TOOL_OPTIONS
  # return [String] string of JAVA_TOOL_OPTIONS
  def default_java_tool_options
    "-Djava.rmi.server.useCodebaseOnly=true"
  end

  # list the available valid ruby versions
  # @note the value is memoized
  # @return [Array] list of Strings of the ruby versions available
  def ruby_versions
    return @ruby_versions if @ruby_versions

    Dir.mktmpdir("ruby_versions-") do |tmpdir|
      Dir.chdir(tmpdir) do
        @fetchers[:buildpack].fetch("ruby_versions.yml")
        @ruby_versions = YAML::load_file("ruby_versions.yml")
      end
    end

    @ruby_versions
  end

  # sets up the environment variables for the build process
  def setup_language_pack_environment
    instrument 'ruby_dev.setup_language_pack_environment' do
      ENV["PATH"] += ":bin" if ruby_version.jruby?
      setup_ruby_install_env
      ENV["PATH"] += ":#{node_bp_bin_path}" if node_js_installed?

      # TODO when buildpack-env-args rolls out, we can get rid of
      # ||= and the manual setting below
      config_vars = default_config_vars.each do |key, value|
        ENV[key] ||= value
      end

      ENV["GEM_PATH"] = slug_vendor_base
      ENV["GEM_HOME"] = slug_vendor_base
      ENV["PATH"]     = default_path
    end
  end

  # sets up the profile.d script for this buildpack
  def setup_profiled
    instrument 'ruby_dev.setup_profiled' do
      set_env_override "GEM_PATH", "$HOME/#{slug_vendor_base}:$GEM_PATH"
      set_env_default  "LANG",     "en_US.UTF-8"
      set_env_override "PATH",     binstubs_relative_paths.map {|path| "$HOME/#{path}" }.join(":") + ":$PATH"

      if ruby_version.jruby?
        set_env_default "JAVA_OPTS", default_java_opts
        set_env_default "JRUBY_OPTS", default_jruby_opts
        set_env_default "JAVA_TOOL_OPTIONS", default_java_tool_options
      end
    end
  end

  # install the vendored ruby
  # @return [Boolean] true if it installs the vendored ruby and false otherwise
  def install_ruby
    instrument 'ruby_dev.install_ruby' do
      return false unless ruby_version

      invalid_ruby_version_message = <<ERROR
Invalid RUBY_VERSION specified: #{ruby_version.version}
Valid versions: #{ruby_versions.join(", ")}
ERROR

      if ruby_version.build?
        FileUtils.mkdir_p(build_ruby_path)
        Dir.chdir(build_ruby_path) do
          ruby_vm = "ruby"
          instrument "ruby_dev.fetch_build_ruby" do
            @fetchers[:mri].fetch_untar("#{ruby_version.version.sub(ruby_vm, "#{ruby_vm}-build")}.tgz")
          end
        end
        error invalid_ruby_version_message unless $?.success?
      end

      FileUtils.mkdir_p(slug_vendor_ruby)
      Dir.chdir(slug_vendor_ruby) do
        instrument "ruby_dev.fetch_ruby" do
          if ruby_version.rbx?
            file     = "#{ruby_version.version}.tar.bz2"
            sha_file = "#{file}.sha1"
            @fetchers[:rbx].fetch(file)
            @fetchers[:rbx].fetch(sha_file)

            expected_checksum = File.read(sha_file).chomp
            actual_checksum   = Digest::SHA1.file(file).hexdigest

            error <<-ERROR_MSG unless expected_checksum == actual_checksum
RBX Checksum for #{file} does not match.
Expected #{expected_checksum} but got #{actual_checksum}.
Please try pushing again in a few minutes.
ERROR_MSG

            run("tar jxf #{file}")
            FileUtils.mv(Dir.glob("app/#{slug_vendor_ruby}/*"), ".")
            FileUtils.rm_rf("app")
            FileUtils.rm(file)
            FileUtils.rm(sha_file)
          else
            @fetchers[:mri].fetch_untar("#{ruby_version.version}.tgz")
          end
        end
      end
      error invalid_ruby_version_message unless $?.success?

      app_bin_dir = "bin"
      FileUtils.mkdir_p app_bin_dir

      run("ln -s ruby #{slug_vendor_ruby}/bin/ruby.exe")

      Dir["#{slug_vendor_ruby}/bin/*"].each do |vendor_bin|
        run("ln -s ../#{vendor_bin} #{app_bin_dir}")
      end

      @metadata.write("buildpack_ruby_version", ruby_version.version)

      topic "Using Ruby version: #{ruby_version.version}"
      if !ruby_version.set
        warn(<<WARNING)
You have not declared a Ruby version in your Gemfile.
To set your Ruby version add this line to your Gemfile:
#{ruby_version.to_gemfile}
# See https://devcenter.heroku.com/articles/ruby-versions for more information.
WARNING
      end
    end

    true
  end

  def new_app?
    @new_app ||= !File.exist?("vendor/heroku")
  end

  # vendors JVM into the slug for JRuby
  def install_jvm
    instrument 'ruby_dev.install_jvm' do
      if ruby_version.jruby?
        jvm_version =
          if Gem::Version.new(ruby_version.engine_version) >= Gem::Version.new("1.7.4")
            LATEST_JVM_VERSION
          else
            LEGACY_JVM_VERSION
          end

        topic "Installing JVM: #{jvm_version}"

        FileUtils.mkdir_p(slug_vendor_jvm)
        Dir.chdir(slug_vendor_jvm) do
          @fetchers[:jvm].fetch_untar("#{jvm_version}.tar.gz")
        end

        bin_dir = "bin"
        FileUtils.mkdir_p bin_dir
        Dir["#{slug_vendor_jvm}/bin/*"].each do |bin|
          run("ln -s ../#{bin} #{bin_dir}")
        end
      end
    end
  end

  # find the ruby install path for its binstubs during build
  # @return [String] resulting path or empty string if ruby is not vendored
  def ruby_install_binstub_path
    @ruby_install_binstub_path ||=
      if ruby_version.build?
        "#{build_ruby_path}/bin"
      elsif ruby_version
        "#{slug_vendor_ruby}/bin"
      else
        ""
      end
  end

  # setup the environment so we can use the vendored ruby
  def setup_ruby_install_env
    instrument 'ruby_dev.setup_ruby_install_env' do
      ENV["PATH"] = "#{ruby_install_binstub_path}:#{ENV["PATH"]}"

      if ruby_version.jruby?
        ENV['JAVA_OPTS']  = default_java_opts
      end
    end
  end

  # installs vendored gems into the slug
  def install_bundler_in_app
    instrument 'ruby_dev.install_language_pack_gems' do
      FileUtils.mkdir_p(slug_vendor_base)
      Dir.chdir(slug_vendor_base) do |dir|
        `cp -R #{bundler.bundler_path}/. .`
      end
    end
  end

  # default set of binaries to install
  # @return [Array] resulting list
  def binaries
    add_node_js_binary
  end

  # vendors individual binary into the slug
  # @param [String] name of the binary package from S3.
  #   Example: https://s3.amazonaws.com/language-pack-ruby/node-0.4.7.tgz, where name is "node-0.4.7"
  def install_binary(name)
    bin_dir = "bin"
    FileUtils.mkdir_p bin_dir
    Dir.chdir(bin_dir) do |dir|
      @fetchers[:buildpack].fetch_untar("#{name}.tgz")
    end
  end

  # removes a binary from the slug
  # @param [String] relative path of the binary on the slug
  def uninstall_binary(path)
    FileUtils.rm File.join('bin', File.basename(path)), :force => true
  end

  def load_default_cache?
    new_app? && ruby_version.default?
  end

  # loads a default bundler cache for new apps to speed up initial bundle installs
  def load_default_cache
    instrument "ruby_dev.load_default_cache" do
      if false # load_default_cache?
        puts "New app detected loading default bundler cache"
        patchlevel = run("ruby -e 'puts RUBY_PATCHLEVEL'").chomp
        cache_name  = "#{DEFAULT_RUBY_VERSION}-p#{patchlevel}-default-cache"
        @fetchers[:buildpack].fetch_untar("#{cache_name}.tgz")
      end
    end
  end

  # install libyaml into the LP to be referenced for psych compilation
  # @param [String] tmpdir to store the libyaml files
  def install_libyaml(dir)
    instrument 'ruby_dev.install_libyaml' do
      FileUtils.mkdir_p dir
      Dir.chdir(dir) do |dir|
        @fetchers[:buildpack].fetch_untar("#{LIBYAML_PATH}.tgz")
      end
    end
  end

  # runs bundler to install the dependencies
  def build_bundler
    instrument 'ruby_dev.build_bundler' do
      log("bundle") do
        bundle_bin     = "bundle"
        bundle_command = "#{bundle_bin} install"
        bundle_command << " -j4"

        if bundler.windows_gemfile_lock?
          warn(<<WARNING, inline: true)
Removing `Gemfile.lock` because it was generated on Windows.
Bundler will do a full resolve so native gems are handled properly.
This may result in unexpected gem versions being used in your app.
In rare occasions Bundler may not be able to resolve your dependencies at all.
https://devcenter.heroku.com/articles/bundler-windows-gemfile
WARNING

          log("bundle", "has_windows_gemfile_lock")
          File.unlink("Gemfile.lock")
        else
          # using --deployment is preferred if we can
          bundle_command += " --deployment"
          cache.load ".bundle"
        end

        topic("Installing dependencies using #{bundler.version}")
        load_bundler_cache

        bundler_output = ""
        bundle_time    = nil
        Dir.mktmpdir("libyaml-") do |tmpdir|
          libyaml_dir = "#{tmpdir}/#{LIBYAML_PATH}"
          install_libyaml(libyaml_dir)

          # need to setup compile environment for the psych gem
          yaml_include   = File.expand_path("#{libyaml_dir}/include").shellescape
          yaml_lib       = File.expand_path("#{libyaml_dir}/lib").shellescape
          pwd            = Dir.pwd
          bundler_path   = "#{pwd}/#{slug_vendor_base}/gems/#{BUNDLER_GEM_PATH}/lib"
          # we need to set BUNDLE_CONFIG and BUNDLE_GEMFILE for
          # codon since it uses bundler.
          env_vars       = {
            "BUNDLE_GEMFILE"                => "#{pwd}/Gemfile",
            "BUNDLE_CONFIG"                 => "#{pwd}/.bundle/config",
            "CPATH"                         => noshellescape("#{yaml_include}:$CPATH"),
            "CPPATH"                        => noshellescape("#{yaml_include}:$CPPATH"),
            "LIBRARY_PATH"                  => noshellescape("#{yaml_lib}:$LIBRARY_PATH"),
            "RUBYOPT"                       => syck_hack,
            "NOKOGIRI_USE_SYSTEM_LIBRARIES" => "true"
          }
          env_vars["BUNDLER_LIB_PATH"] = "#{bundler_path}" if ruby_version.ruby_version == "1.8.7"
          puts "Running: #{bundle_command}"
          instrument "ruby_dev.bundle_install" do
            bundle_time = Benchmark.realtime do
              bundler_output << pipe("#{bundle_command} --no-clean", out: "2>&1", env: env_vars, user_env: true)
            end
          end
        end

        if $?.success?
          puts "Bundle completed (#{"%.2f" % bundle_time}s)"
          log "bundle", :status => "success"
          puts "Cleaning up the bundler cache."
          instrument "ruby_dev.bundle_clean" do
            pipe("#{bundle_bin} clean", out: "2> /dev/null")
          end

          # Keep gem cache out of the slug
          FileUtils.rm_rf("#{slug_vendor_base}/cache")
        else
          log "bundle", :status => "failure"
          error_message = "Failed to install gems via Bundler."
          puts "Bundler Output: #{bundler_output}"
          if bundler_output.match(/An error occurred while installing sqlite3/)
            error_message += <<ERROR


Detected sqlite3 gem which is not supported on Heroku.
https://devcenter.heroku.com/articles/sqlite3
ERROR
          end

          error error_message
        end
      end
    end
  end

  # RUBYOPT line that requires syck_hack file
  # @return [String] require string if needed or else an empty string
  def syck_hack
    instrument "ruby_dev.syck_hack" do
      syck_hack_file = File.expand_path(File.join(File.dirname(__FILE__), "../../vendor/syck_hack"))
      rv             = run_stdout('ruby -e "puts RUBY_VERSION"').chomp
      # < 1.9.3 includes syck, so we need to use the syck hack
      if Gem::Version.new(rv) < Gem::Version.new("1.9.3")
        "-r#{syck_hack_file}"
      else
        ""
      end
    end
  end

  # executes the block with GIT_DIR environment variable removed since it can mess with the current working directory git thinks it's in
  # @param [block] block to be executed in the GIT_DIR free context
  def allow_git(&blk)
    git_dir = ENV.delete("GIT_DIR") # can mess with bundler
    blk.call
    ENV["GIT_DIR"] = git_dir
  end

  # decides if we need to install the node.js binary
  # @note execjs will blow up if no JS RUNTIME is detected and is loaded.
  # @return [Array] the node.js binary path if we need it or an empty Array
  def add_node_js_binary
    bundler.has_gem?('execjs') && !node_js_installed? ? [NODE_JS_BINARY_PATH] : []
  end

  def node_bp_bin_path
    "#{Dir.pwd}/#{NODE_BP_PATH}"
  end

  # checks if node.js is installed via the official heroku-buildpack-nodejs using multibuildpack
  # @return [Boolean] true if it's detected and false if it isn't
  def node_js_installed?
    @node_js_installed ||= run("#{node_bp_bin_path}/node -v") && $?.success?
  end
end
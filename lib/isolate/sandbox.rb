require "fileutils"
require "isolate/entry"
require "isolate/events"
require "rbconfig"
require "rubygems/defaults"
require "rubygems/uninstaller"

module Isolate
  class Sandbox
    include Events

    attr_reader :entries # :nodoc:
    attr_reader :environments # :nodoc:
    attr_reader :files # :nodoc:

    # Create a new Isolate instance. See Isolate.gems for the public
    # API. You probably don't want to use this constructor directly.

    def initialize options = {}, &block
      @enabled      = false
      @entries      = []
      @environments = []
      @files        = []
      @options      = options

      file, local = nil

      fire :initializing

      unless FalseClass === options[:file]
        file  = options[:file] || Dir["{Isolate,config/isolate.rb}"].first
        local = "#{file}.local" if file
      end

      load file if file

      if block_given?
        block.to_s =~ /\@([^:]+):/
        files << ($1 || "inline block")
        instance_eval(&block)
      end

      load local if local && File.exist?(local)
      fire :initialized
    end

    # Activate this set of isolated entries, respecting an optional
    # +environment+. Points RubyGems to a separate repository, messes
    # with paths, auto-installs gems (if necessary), activates
    # everything, and removes any superfluous gem (again, if
    # necessary). If +environment+ isn't specified, +ISOLATE_ENV+,
    # +RAILS_ENV+, and +RACK_ENV+ are checked before falling back to
    # <tt>"development"</tt>.

    def activate environment = nil
      enable unless enabled?
      fire :activating

      env = (environment || Isolate.env).to_s

      install env if install?

      entries.each do |e|
        e.activate if e.matches? env
      end

      cleanup if cleanup?
      fire :activated

      self
    end

    def cleanup # :nodoc:
      fire :cleaning

      activated = Gem.loaded_specs.values.map { |s| s.full_name }
      available = Gem.source_index.gems.values.sort

      extra = available.reject do |spec|
        active = activated.include? spec.full_name
        entry  = entries.find { |e| e.matches_spec? spec }
        system = !spec.loaded_from.include?(path)

        active or entry or system
      end

      unless extra.empty?
        padding = Math.log10(extra.size).to_i + 1
        format  = "[%0#{padding}d/%s] Nuking %s."

        extra.each_with_index do |e, i|
          log format % [i + 1, extra.size, e.full_name]

          Gem::DefaultUserInteraction.use_ui Gem::SilentUI.new do
            Gem::Uninstaller.new(e.name,
                                 :version     => e.version,
                                 :ignore      => true,
                                 :executables => true,
                                 :install_dir => path).uninstall
          end
        end
      end

      fire :cleaned
    end

    def cleanup?
      install? and @options.fetch(:cleanup, true)
    end

    def disable &block
      return self if not enabled?
      fire :disabling

      ENV["GEM_PATH"] = @old_gem_path
      ENV["GEM_HOME"] = @old_gem_home
      ENV["ISOLATED"] = @old_isolated
      ENV["PATH"]     = @old_path
      ENV["RUBYOPT"]  = @old_ruby_opt

      $LOAD_PATH.replace @old_load_path

      @enabled = false

      Isolate.refresh
      fire :disabled

      begin; return yield ensure enable end if block_given?

      self
    end

    def enable # :nodoc:
      return self if enabled?
      fire :enabling

      @old_gem_path  = ENV["GEM_PATH"]
      @old_gem_home  = ENV["GEM_HOME"]
      @old_isolated  = ENV["ISOLATED"]
      @old_path      = ENV["PATH"]
      @old_ruby_opt  = ENV["RUBYOPT"]
      @old_load_path = $LOAD_PATH.dup

      FileUtils.mkdir_p path
      ENV["GEM_HOME"] = path

      unless system?
        $LOAD_PATH.reject! do |p|
          p != File.dirname(__FILE__) &&
            Gem.path.any? { |gp| p.include?(gp) }
        end

        # HACK: Gotta keep isolate explicitly in the LOAD_PATH in
        # subshells, and the only way I can think of to do that is by
        # abusing RUBYOPT.

        dirname = Regexp.escape File.dirname(__FILE__)

        unless ENV["RUBYOPT"] =~ /\s+-I\s*#{dirname}\b/
          ENV["RUBYOPT"] = "#{ENV['RUBYOPT']} -I#{File.dirname(__FILE__)}"
        end

        ENV["GEM_PATH"] = path
      end

      bin = File.join path, "bin"

      unless ENV["PATH"].split(File::PATH_SEPARATOR).include? bin
        ENV["PATH"] = [bin, ENV["PATH"]].join File::PATH_SEPARATOR
      end

      ENV["ISOLATED"] = path

      Isolate.refresh
      Gem.path.unshift path if system?

      @enabled = true
      fire :enabled

      self
    end

    def enabled?
      @enabled
    end

    # Restricts +gem+ calls inside +block+ to a set of +environments+.

    def environment *environments, &block
      old = @environments
      @environments = @environments.dup.concat environments.map { |e| e.to_s }

      instance_eval(&block)
    ensure
      @environments = old
    end

    alias_method :env, :environment

    # Express a gem dependency. Works pretty much like RubyGems' +gem+
    # method, but respects +environment+ and doesn't activate 'til
    # later.

    def gem name, *requirements
      entry = entries.find { |e| e.name == name }
      return entry.update(*requirements) if entry

      entries << entry = Entry.new(self, name, *requirements)
      entry
    end

    def install environment # :nodoc:
      fire :installing

      installable = entries.select do |e|
        !Gem.available?(e.name, *e.requirement.as_list) &&
          e.matches?(environment)
      end

      unless installable.empty?
        padding = Math.log10(installable.size).to_i + 1
        format  = "[%0#{padding}d/%s] Isolating %s (%s)."

        installable.each_with_index do |entry, i|
          log format % [i + 1, installable.size, entry.name, entry.requirement]
          entry.install
        end

        Gem.source_index.refresh!
      end

      fire :installed

      self
    end

    def install? # :nodoc:
      @options.fetch :install, true
    end

    def load file # :nodoc:
      files << file
      instance_eval IO.read(file), file, 1
    end

    def log s # :nodoc:
      $stderr.puts s if verbose?
    end


    def multiruby?
      @options.fetch :multiruby, true
    end

    def options options = nil
      @options.merge! options if options
      @options
    end

    def path
      base = @options.fetch :path, "tmp/isolate"

      unless @options.key?(:multiruby) && @options[:multiruby] == false
        suffix = "#{Gem.ruby_engine}-#{RbConfig::CONFIG['ruby_version']}"
        base   = File.join(base, suffix) unless base =~ /#{suffix}/
      end

      File.expand_path base
    end

    def system?
      @options.fetch :system, true
    end

    def verbose?
      @options.fetch :verbose, true
    end
  end
end

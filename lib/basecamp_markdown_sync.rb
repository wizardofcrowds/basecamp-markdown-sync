# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "set"
require "tempfile"
require "uri"
require "yaml"

module BasecampMarkdownSync
  VERSION = "0.4.0"
  class Error < StandardError; end

  def self.command(args, root:, body: "")
    out, err, status = Open3.capture3({ "BASECAMP_NONINTERACTIVE" => "1" }, *args,
                                    chdir: root.to_s, stdin_data: body)
    raise Error, "Command failed: #{args.join(' ')}\n#{err.empty? ? out : err}" unless status.success?
    out
  end

  # Basecamp URL for a synced item, keeping a heading fragment when given.
  def self.link_url(entries, target, fragment)
    url = entries.fetch(target).fetch("url")
    fragment.nil? || fragment.empty? ? url : "#{url}##{fragment}"
  end

  # GitHub-style heading slug: lowercase, punctuation removed except hyphens
  # and underscores, spaces become hyphens.
  def self.slug(text)
    text.downcase.gsub(/[^\p{L}\p{M}\p{N}\p{Pc} -]/u, "").tr(" ", "-")
  end

  def self.save_state(path, state)
    FileUtils.mkdir_p(path.dirname)
    Tempfile.create([path.basename.to_s, ".tmp"], path.dirname.to_s) do |file|
      file.write(JSON.pretty_generate(state))
      file.flush
      file.fsync
      File.rename(file.path, path)
    end
  end

  class CLI
    def initialize(root, config, runner: BasecampMarkdownSync.method(:command))
      @root, @runner = root, runner
      @scope = ["--account", config.fetch("account").to_s, "--in", config.fetch("project").to_s]
      @scope += ["--profile", config["profile"]] if config["profile"]
      @folder = config["vault"] ? ["--vault", config["vault"].to_s] : []
    end

    def call(args, body: "")
      value = JSON.parse(@runner.call(["basecamp", "files", *args, *@scope, "--json"], root: @root, body: body))
      raise Error, value.inspect if value["ok"] == false
      value.fetch("data", value)
    end

    def create(path, markdown:)
      if markdown
        call(["documents", "create", path, "-", "--no-subscribe", *@folder],
             body: "Sync in progress. Content will follow.")
      else
        call(["uploads", "create", (@root / path).to_s, *@folder])
      end
    end

    def update(path, entry, content:)
      if content
        call(["update", entry.fetch("id").to_s, "--type", "document", "--title", path,
              "--content", "-", "--format", "html"], body: content)
      else
        call(["replace", entry.fetch("id").to_s, (@root / path).to_s])
      end
    end
  end

  # Uses a real Markdown tree; links in code spans/blocks are never visited.
  class Markdown
    def initialize(source)
      require "kramdown"
      require "kramdown-parser-gfm"
      @source = source
      @document = parse
      reject_source_html(@document.root)
    end

    def parse
      Kramdown::Document.new(@source, input: "GFM", hard_wrap: false,
                                      syntax_highlighter: nil, auto_ids: false)
    end

    def reject_source_html(node)
      # Raw HTML can contain links outside the Markdown AST. Refuse it rather
      # than silently publish broken href/src attributes.
      if [:html_element, :xml_comment, :xml_pi, :doctype, :raw].include?(node.type)
        # GFM creates del elements for strikethrough; these have parsed children.
        unless (node.type == :html_element && node.value == "del" && !node.children.empty?) || task_checkbox?(node)
          raise Error, "Raw HTML is unsupported; use Markdown links and images instead"
        end
      end
      descendants(node).each { |child| reject_source_html(child) }
    end

    # GFM task lists ("- [ ]") produce disabled checkbox inputs. They carry no
    # links, and Basecamp cannot show form inputs, so they render as text.
    def task_checkbox?(node)
      node.type == :html_element && node.value == "input" && node.children.empty? &&
        node.attr["type"] == "checkbox" && node.attr["class"].to_s.split.include?("task-list-item-checkbox")
    end

    def descendants(node)
      # Kramdown stores a footnote's content in value, outside children.
      node.type == :footnote ? node.children + [node.value] : node.children
    end

    def links(node = @document.root, &block)
      case node.type
      when :a then yield node, "href"
      when :img then yield node, "src"
      end
      descendants(node).each { |child| links(child, &block) }
    end

    def render(entries)
      # Render a fresh tree so the parsed one stays reusable. (Kramdown 2.6
      # trees cannot be deep-copied with Marshal.) Links are visited in the
      # same order in both trees, so sync decisions carry over by position.
      document = parse
      originals = enum_for(:links, @document.root).map { |node, _| node }
      copies = enum_for(:links, document.root).map { |node, _| node }
      originals.zip(copies) do |original, copy|
        copy.options.merge!(original.options.slice(:sync_target, :sync_fragment, :sync_unlink))
      end
      anchor_headings(document.root)
      transform(document.root, entries)
      document.to_html
    end

    # Basecamp strips id attributes but keeps <a name>, so each heading gets a
    # named anchor matching the GitHub slug that repository links use.
    def anchor_headings(root)
      seen = Hash.new(0)
      headers = []
      collect = lambda do |node|
        headers << node if node.type == :header
        descendants(node).each { |child| collect.call(child) if child.is_a?(Kramdown::Element) }
      end
      collect.call(root)
      headers.each do |header|
        base = BasecampMarkdownSync.slug(heading_text(header))
        name = seen[base].zero? ? base : "#{base}-#{seen[base]}"
        seen[base] += 1
        next if name.empty?
        header.children.unshift(Kramdown::Element.new(:html_element, "a", { "name" => name }, category: :span))
      end
    end

    TYPOGRAPHIC_SOURCE = { ndash: "--", mdash: "---", hellip: "...", laquo: "<<", raquo: ">>",
                           laquo_space: "<< ", raquo_space: " >>" }.freeze

    def heading_text(node)
      case node.type
      when :text, :codespan then node.value.to_s
      when :smart_quote then "'"
      # Kramdown turns "--", "---" and "..." into symbols; slug the source text
      # as GitHub does.
      when :typographic_sym then TYPOGRAPHIC_SOURCE.fetch(node.value, "")
      when :entity then node.value.char.to_s
      else node.children.map { |child| heading_text(child) }.join
      end
    end

    def transform(node, entries)
      if (target = node.options[:sync_target])
        url = BasecampMarkdownSync.link_url(entries, target, node.options[:sync_fragment])
        if node.type == :img
          label = node.attr["alt"].to_s
          label = target if label.empty?
          node.type = :a
          node.attr.clear
          node.attr["href"] = url
          node.children = [Kramdown::Element.new(:text, label)]
        else
          node.attr["href"] = url
        end
      end
      node.children = node.children.flat_map do |child|
        if task_checkbox?(child)
          [Kramdown::Element.new(:text, child.attr.key?("checked") ? "\u2611 " : "\u2610 ")]
        elsif child.options[:sync_unlink]
          unlinked(child)
        else
          [child]
        end
      end
      descendants(node).each { |child| transform(child, entries) }
    end

    # A link to a document the operator chose not to publish keeps its text
    # but loses the link, so no broken repository path reaches Basecamp.
    def unlinked(node)
      node.type == :img ? [Kramdown::Element.new(:text, node.attr["alt"].to_s)] : node.children
    end
  end

  class Publisher
    attr_reader :sources, :warnings, :docs, :dependencies, :declined

    def initialize(root, config, state, cli, parser: Markdown)
      @root, @config, @state, @cli, @parser = root.realpath, config, state, cli, parser
      tracked = BasecampMarkdownSync.command(["git", "ls-files", "-z"], root: @root).split("\0")
      @docs = tracked.select do |path|
        File.extname(path).downcase == ".md" &&
          matches?(path, config.fetch("include", ["**/*.md", "*.md"])) &&
          !matches?(path, config.fetch("exclude", []))
      end.sort
      @sources, @documents, @assets, @warnings = {}, {}, Set.new, Set.new
      @dependencies, @declined = Set.new, Set.new
    end

    # Maps a command-line path (relative to the working directory) to a
    # repository-relative document selected by the configuration.
    def document_path(argument)
      file = Pathname(argument).expand_path
      file = file.realpath if file.exist?
      relative = file.relative_path_from(@root).to_s
      return relative if @docs.include?(relative)
      raise Error, "#{argument}: not a Git-tracked Markdown document selected by include/exclude"
    end

    def matches?(path, patterns)
      patterns.any? do |pattern|
        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH) ||
          (pattern.end_with?("/**") && path.start_with?(pattern.delete_suffix("**")))
      end
    end

    def read(path)
      file = (@root / path).realpath
      unless file.to_s.start_with?(@root.to_s + File::SEPARATOR) && file.file?
        raise Error, "Path outside repository or not a file: #{path}"
      end
      file.binread
    rescue Errno::ENOENT
      raise Error, "Missing local file: #{path}"
    end

    def target(source, url)
      return nil if url.match?(/\A[a-z][a-z0-9+.-]*:/i) || url.start_with?("//")
      path = url.split(/[?#]/, 2).first
      query = url.split("#", 2).first.include?("?")
      return nil if (path.nil? || path.empty?) && !url.start_with?("#")
      @warnings << "#{source}: query removed from local link #{url.inspect}" if query
      return source if path.nil? || path.empty?
      decoded = URI::DEFAULT_PARSER.unescape(path).force_encoding(Encoding::UTF_8)
      base = decoded.start_with?("/") ? @root : (@root / source).dirname
      file = (base / decoded.sub(%r{\A/+}, "")).cleanpath
      unless file.to_s.start_with?(@root.to_s + File::SEPARATOR)
        raise Error, "#{source}: link escapes repository: #{url}"
      end
      relative = file.relative_path_from(@root).to_s
      unless @docs.include?(relative)
        raise Error, "#{source}: linked Markdown is excluded or untracked: #{url}" if File.extname(relative).downcase == ".md"
        read(relative)
        @assets << relative
      end
      relative
    end

    # With only:, publishes just those documents. A linked document that is
    # neither selected nor already on Basecamp is passed to decide(source,
    # target): true adds it (and, in turn, its links); false publishes the
    # link as plain text.
    def prepare(only: nil, decide: nil)
      entries = @state.fetch("entries")
      queue = only ? only.map { |path| document_path(path) }.uniq : @docs.dup
      queued = queue.to_set
      until queue.empty?
        path = queue.shift
        begin
          @sources[path] = read(path)
          source = @sources[path].dup.force_encoding(Encoding::UTF_8)
          raise Error, "Markdown must be UTF-8" unless source.valid_encoding?
          document = @parser.new(source)
          document.links do |node, attribute|
            href = node.attr.fetch(attribute)
            target = target(path, href)
            fragment = href.split("#", 2)[1]
            node.options[:sync_fragment] = URI::DEFAULT_PARSER.unescape(fragment) if target && fragment && !fragment.empty?
            if target && @docs.include?(target) && !queued.include?(target) && !entries.key?(target)
              if @declined.include?(target) || !decide.call(path, target)
                @declined << target
                node.options[:sync_unlink] = true
                next
              end
              queued << target
              queue << target
              @dependencies << target
            end
            node.options[:sync_target] = target
          end
          @documents[path] = document
        rescue Error => e
          raise Error, "#{path}: #{e.message}"
        end
      end
      @assets.each { |path| @sources[path] = read(path) }
      self
    end

    def sync(out: $stdout, &save)
      entries = @state.fetch("entries")
      if @state["pending_create"]
        raise Error, "Unconfirmed create for #{@state['pending_create']}. Inspect Basecamp and reconcile state; see README."
      end
      @sources.keys.sort.each do |path|
        next if entries.key?(path)
        @state["pending_create"] = path
        save.call
        result = @cli.create(path, markdown: @docs.include?(path))
        url = result["app_url"]
        unless result["id"] && url && %w[3.basecamp.com app.basecamp.com].include?(URI.parse(url).host) && URI.parse(url).scheme == "https"
          raise Error, "Create returned no usable ID/app_url for #{path}; inspect Basecamp before retrying"
        end
        entries[path] = { "id" => result["id"], "url" => url }
        entries[path]["hash"] = Digest::SHA256.hexdigest(@sources[path]) unless @docs.include?(path)
        @state.delete("pending_create")
        save.call
      end
      @sources.keys.sort.each do |path|
        content = @documents[path]&.render(entries)
        hash = Digest::SHA256.hexdigest(content || @sources.fetch(path))
        next if entries[path]["hash"] == hash
        @cli.update(path, entries[path], content: content)
        entries[path]["hash"] = hash
        save.call
        out.puts "Updated #{path}"
      end
    end
  end

  def self.run(argv, out: $stdout, err: $stderr, input: $stdin)
    config_file = "basecamp-sync.yml"
    with_dependencies = false
    options = OptionParser.new do |parser|
      parser.banner = "Usage: basecamp-md-sync [plan|sync] [options] [FILE...]\n\n" \
                      "With FILE arguments, only those documents are published. Linked documents\n" \
                      "not yet on Basecamp are offered for upload; declined links become plain text.\n\n"
      parser.on("--config FILE", "YAML configuration file") { |file| config_file = file }
      parser.on("--with-dependencies", "With FILE arguments, upload linked documents without asking") do
        with_dependencies = true
      end
      parser.on("--version") { out.puts VERSION; return 0 }
      parser.on("-h", "--help") { out.puts parser; return 0 }
    end
    options.parse!(argv)
    action = argv.shift
    raise Error, options.to_s unless ["plan", "sync"].include?(action)
    files = argv.dup
    raise Error, "--with-dependencies requires FILE arguments" if with_dependencies && files.empty?
    config_path = Pathname(config_file).expand_path
    config = YAML.safe_load_file(config_path, permitted_classes: [], aliases: false)
    raise Error, "Configuration must be a YAML mapping" unless config.is_a?(Hash)
    root = (config_path.dirname / config.fetch("repository", ".")).realpath
    git_root = Pathname(command(["git", "rev-parse", "--show-toplevel"], root: root).strip).realpath
    raise Error, "repository must name the Git repository root" unless root == git_root
    %w[account project].each do |key|
      raise Error, "#{key} must be an explicit numeric ID" unless config.fetch(key).to_s.match?(/\A\d+\z/)
    end
    state_path = (config_path.dirname / config.fetch("state", ".basecamp-md-sync-state.json")).expand_path
    identity = %w[account project vault profile].to_h { |key| [key, config.fetch(key, "").to_s] }
    identity["repository"] = root.to_s
    state = state_path.exist? ? JSON.parse(state_path.read) : { "target" => identity, "entries" => {} }
    raise Error, "State belongs to a different repository or destination; use a separate state file" unless state["target"] == identity
    decide = lambda do |source, target|
      next true if with_dependencies
      if action == "plan"
        out.puts "ask: #{target} (linked from #{source}; not on Basecamp yet)"
        next false
      end
      unless input.respond_to?(:tty?) && input.tty?
        raise Error, "links to #{target}, which is not on Basecamp yet. " \
                     "Run interactively to choose, or pass --with-dependencies to upload it"
      end
      err.print "#{source} links to #{target}, which is not on Basecamp yet. Upload it too? [y/N] "
      next true if input.gets.to_s.strip.match?(/\Ay(es)?\z/i)
      err.puts "Not uploading #{target}; links to it will be plain text."
      false
    end
    publisher = Publisher.new(root, config, state, CLI.new(root, config))
    publisher.prepare(only: files.empty? ? nil : files, decide: decide)
    publisher.sources.keys.sort.each do |path|
      status = state.fetch("entries").key?(path) ? "existing (compare on sync)" : "create"
      status += " (linked dependency)" if publisher.dependencies.include?(path)
      out.puts "#{status}: #{path}"
    end
    publisher.warnings.sort.each { |warning| err.puts "Warning: #{warning}" }
    return 0 if action == "plan"
    FileUtils.mkdir_p(state_path.dirname)
    File.open("#{state_path}.lock", "w") do |lock|
      raise Error, "Another sync is using this state file" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      if state_path.exist? && JSON.parse(state_path.read) != state
        raise Error, "State changed during planning; rerun sync"
      end
      profile = config["profile"] ? ["--profile", config["profile"]] : []
      instructions = command(["basecamp", "instructions", *profile], root: root).strip
      unless instructions.empty? || instructions == "No instructions to follow: none are set."
        raise Error, "Basecamp has operator instructions. Review and apply these before automated publishing:\n#{instructions}"
      end
      publisher.sync(out: out) { save_state(state_path, state) }
    end
    0
  rescue Error, SystemCallError, JSON::ParserError, Psych::Exception, OptionParser::ParseError,
         KeyError, ArgumentError, URI::InvalidURIError, LoadError => e
    err.puts "Error: #{e.message}"
    1
  end
end

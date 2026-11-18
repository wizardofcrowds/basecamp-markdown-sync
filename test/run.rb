# frozen_string_literal: true

# Standard-library test runner so CLI/state/engine checks run without gems.
require_relative "../lib/basecamp_markdown_sync"
require "tmpdir"
require "stringio"

Sync = BasecampMarkdownSync
$passed = $failed = $skipped = 0

def assert(value, message = "Assertion failed")
  raise message unless value
end

def equal(expected, actual)
  assert(expected == actual, "Expected #{expected.inspect}, got #{actual.inspect}")
end

def raises(type)
  begin
    yield
  rescue type => error
    return error
  end
  raise "Expected #{type}"
end

def test(name)
  yield
  $passed += 1
  puts "PASS #{name}"
rescue StandardError => e
  $failed += 1
  warn "FAIL #{name}: #{e.message}\n  #{e.backtrace.first}"
end

class FakeCLI
  attr_reader :created, :updated
  attr_accessor :fail_create, :fail_update

  def initialize
    @created, @updated = [], []
  end

  def create(path, markdown:)
    raise Sync::Error, "create failed" if fail_create
    @created << [path, markdown]
    { "id" => @created.size, "app_url" => "https://3.basecamp.com/1/buckets/2/documents/#{@created.size}" }
  end

  def update(path, entry, content:)
    raise Sync::Error, "update failed" if fail_update
    @updated << [path, entry.fetch("id"), content]
  end
end

# A deliberately simple injected AST fixture. Engine tests do not claim to
# validate Markdown syntax; separate tests below use the actual Kramdown parser.
class ASTFixture
  Node = Struct.new(:attr, :options)

  def initialize(source)
    @data = JSON.parse(source)
    @nodes = @data.fetch("links", []).map { |url| Node.new({ "href" => url }, {}) }
  end

  def links
    @nodes.each { |node| yield node, "href" }
  end

  def render(entries)
    JSON.generate([@data["text"], @nodes.map do |node|
      next "(unlinked)" if node.options[:sync_unlink]
      node.options[:sync_target] ? Sync.link_url(entries, node.options[:sync_target], node.options[:sync_fragment]) : node.attr["href"]
    end])
  end
end

def repository
  Dir.mktmpdir("basecamp-sync-test") do |dir|
    root = Pathname(dir).realpath
    Sync.command(["git", "init", "-q"], root: root)
    yield root, { "entries" => {} }, FakeCLI.new
  end
end

def put(root, path, source)
  file = root / path
  file.dirname.mkpath
  file.write(source)
  Sync.command(["git", "add", "--", path], root: root)
end

def document(root, path, links = [], text: "hello")
  put(root, path, JSON.generate("links" => links, "text" => text))
end

def engine(root, state, cli, config = {}, only: nil, decide: nil)
  Sync::Publisher.new(root, config, state, cli, parser: ASTFixture).prepare(only: only, decide: decide)
end

def asker(answers)
  asked = []
  [asked, ->(source, target) { asked << [source, target]; answers.fetch(target) }]
end

def publish(publisher, root, state)
  publisher.sync(out: StringIO.new) { Sync.save_state(root / "state.json", state) }
end

test("atomic state replacement and UTF-8") do
  Dir.mktmpdir do |dir|
    file = Pathname(dir) / "nested/state.json"
    state = { "entries" => { "日本語.md" => { "id" => 1 } } }
    Sync.save_state(file, state)
    equal(state, JSON.parse(file.read))
    Sync.save_state(file, { "entries" => {} })
    equal({ "entries" => {} }, JSON.parse(file.read))
    equal(["state.json"], file.dirname.children.map { |p| p.basename.to_s })
  end
end

test("CLI scopes requests, sends body on stdin, and preserves IDs") do
  calls = []
  runner = lambda do |args, **kwargs|
    calls << [args, kwargs]
    '{"ok":true,"data":{"id":12}}'
  end
  cli = Sync::CLI.new(Pathname("/tmp"), { "account" => 1, "project" => 2, "vault" => 3, "profile" => "human" }, runner: runner)
  equal({ "id" => 12 }, cli.create("a.md", markdown: true))
  args, options = calls.last
  assert(args.include?("--no-subscribe"))
  equal("1", args[args.index("--account") + 1])
  equal("2", args[args.index("--in") + 1])
  equal("3", args[args.index("--vault") + 1])
  assert(!options[:body].empty?)
  cli.update("a.md", { "id" => 12 }, content: "<p>body</p>")
  equal(["update", "12"], calls.last.first[2, 2])
  equal("<p>body</p>", calls.last.last[:body])
  cli.update("a.pdf", { "id" => 12 }, content: nil)
  equal(["replace", "12", "/tmp/a.pdf"], calls.last.first[2, 3])
end

test("CLI error envelope stops without retries") do
  calls = 0
  runner = ->(*, **) { calls += 1; '{"ok":false,"error":"denied"}' }
  cli = Sync::CLI.new(Pathname("/tmp"), { "account" => 1, "project" => 2 }, runner: runner)
  raises(Sync::Error) { cli.create("a.md", markdown: true) }
  equal(1, calls)
end

test("subprocess args are literal and failures propagate") do
  literal = "`touch injected`; $(echo bad)\n日本語"
  equal(literal, Sync.command([RbConfig.ruby, "-e", "print ARGV[0]", literal], root: Pathname(Dir.pwd)))
  raises(Sync::Error) { Sync.command([RbConfig.ruby, "-e", "warn 'denied'; exit 1"], root: Pathname(Dir.pwd)) }
end

test("help and invalid options") do
  out, err = StringIO.new, StringIO.new
  equal(0, Sync.run(["--help"], out: out, err: err))
  assert(out.string.include?("--config"))
  equal(1, Sync.run(["--unknown"], out: out, err: err))
end

test("circular links resolve and repeat sync is unchanged") do
  repository do |root, state, cli|
    document(root, "a.md", ["sub/b.md"])
    document(root, "sub/b.md", ["../a.md"])
    publish(engine(root, state, cli), root, state)
    equal(2, cli.created.size)
    assert(cli.updated.first.last.include?(state["entries"]["sub/b.md"]["url"]))
    publish(engine(root, state, cli), root, state)
    equal(2, cli.created.size)
    equal(2, cli.updated.size)
  end
end

test("referenced assets upload, URL encoding and root-relative paths resolve") do
  repository do |root, state, cli|
    document(root, "sub/a.md", ["../images/my%20image.png", "/file.pdf"])
    put(root, "images/my image.png", "image")
    put(root, "file.pdf", "pdf")
    publish(engine(root, state, cli), root, state)
    equal(3, cli.created.size)
    equal(1, cli.updated.size)
  end
end

test("changed asset replaces file without updating unchanged document") do
  repository do |root, state, cli|
    document(root, "a.md", ["file.pdf"])
    put(root, "file.pdf", "first")
    publish(engine(root, state, cli), root, state)
    id = state["entries"]["file.pdf"]["id"]
    put(root, "file.pdf", "second")
    cli.updated.clear
    publish(engine(root, state, cli), root, state)
    equal([["file.pdf", id, nil]], cli.updated)
  end
end

test("missing links fail before writes") do
  repository do |root, state, cli|
    document(root, "a.md", ["missing.pdf"])
    raises(Sync::Error) { engine(root, state, cli) }
    equal([], cli.created)
  end
end

test("excluded nested Markdown and untracked Markdown fail") do
  repository do |root, state, cli|
    document(root, "a.md", ["private/deep/b.md"])
    document(root, "private/deep/b.md")
    raises(Sync::Error) { engine(root, state, cli, { "exclude" => ["private/**"] }) }
    document(root, "a.md", ["untracked.md"])
    (root / "untracked.md").write("untracked")
    raises(Sync::Error) { engine(root, state, cli) }
  end
end

test("path and symlink escapes fail") do
  repository do |root, state, cli|
    document(root, "a.md", ["../outside.pdf"])
    raises(Sync::Error) { engine(root, state, cli) }
    document(root, "a.md", ["escape.txt"])
    File.symlink("/etc/hosts", root / "escape.txt")
    raises(Sync::Error) { engine(root, state, cli) }
  end
end

test("fragments are kept, queries warn; external links stay intact") do
  repository do |root, state, cli|
    document(root, "a.md", ["b.md?raw=1#heading", "#self", "b.md#two-words", "https://example.org/a.md", "mailto:a@example.org"])
    document(root, "b.md")
    publisher = engine(root, state, cli)
    equal(1, publisher.warnings.size)
    publish(publisher, root, state)
    content = JSON.parse(cli.updated.first.last)
    b, a = state["entries"]["b.md"]["url"], state["entries"]["a.md"]["url"]
    equal(["#{b}#heading", "#{a}#self", "#{b}#two-words", "https://example.org/a.md", "mailto:a@example.org"], content.last)
  end
end

test("app.basecamp.com create URLs are accepted; other hosts stop the run") do
  repository do |root, state, cli|
    document(root, "a.md")
    url = "https://app.basecamp.com/1/buckets/2/documents/3"
    cli.define_singleton_method(:create) { |*, **| { "id" => 3, "app_url" => url } }
    publish(engine(root, state, cli), root, state)
    equal(url, state["entries"]["a.md"]["url"])
    document(root, "b.md")
    cli.define_singleton_method(:create) { |*, **| { "id" => 4, "app_url" => "https://evil.example/documents/4" } }
    raises(Sync::Error) { publish(engine(root, state, cli), root, state) }
    equal("b.md", state["pending_create"])
  end
end

test("interrupted updates resume without duplicate creation") do
  repository do |root, state, cli|
    document(root, "a.md", ["b.md"])
    document(root, "b.md")
    cli.fail_update = true
    raises(Sync::Error) { publish(engine(root, state, cli), root, state) }
    equal(2, JSON.parse((root / "state.json").read)["entries"].size)
    cli.fail_update = false
    publish(engine(root, state, cli), root, state)
    equal(2, cli.created.size)
    equal(2, cli.updated.size)
  end
end

test("ambiguous creates persist marker and block retry") do
  repository do |root, state, cli|
    document(root, "a.md")
    cli.fail_create = true
    raises(Sync::Error) { publish(engine(root, state, cli), root, state) }
    equal("a.md", JSON.parse((root / "state.json").read)["pending_create"])
    cli.fail_create = false
    raises(Sync::Error) { publish(engine(root, state, cli), root, state) }
    equal([], cli.created)
  end
end

test("file selection publishes only named documents and links to published ones") do
  repository do |root, state, cli|
    document(root, "a.md", ["b.md"])
    document(root, "b.md")
    document(root, "c.md")
    publish(engine(root, state, cli), root, state)
    cli.created.clear
    cli.updated.clear
    document(root, "a.md", ["b.md"], text: "changed")
    document(root, "b.md", [], text: "changed too")
    asked, decide = asker({})
    publish(engine(root, state, cli, only: [(root / "a.md").to_s], decide: decide), root, state)
    equal([], asked)
    equal([], cli.created)
    equal(["a.md"], cli.updated.map(&:first))
    equal([state["entries"]["b.md"]["url"]], JSON.parse(cli.updated.first.last).last)
  end
end

test("file selection rejects unselected, excluded and unknown paths") do
  repository do |root, state, cli|
    document(root, "a.md")
    document(root, "private/b.md")
    (root / "notes.txt").write("x")
    [root / "private/b.md", root / "missing.md", root / "notes.txt", root.dirname / "x.md"].each do |path|
      raises(Sync::Error) { engine(root, state, cli, { "exclude" => ["private/**"] }, only: [path.to_s], decide: ->(*) { true }) }
    end
  end
end

test("declined unpublished dependencies become plain text and are asked once") do
  repository do |root, state, cli|
    document(root, "a.md", ["secret.md", "secret.md#part", "img.png"])
    document(root, "secret.md")
    put(root, "img.png", "png")
    asked, decide = asker("secret.md" => false)
    publisher = engine(root, state, cli, only: [(root / "a.md").to_s], decide: decide)
    equal([["a.md", "secret.md"]], asked)
    equal(Set["secret.md"], publisher.declined)
    publish(publisher, root, state)
    equal(["a.md", "img.png"], cli.created.map(&:first).sort)
    assert(!state["entries"].key?("secret.md"))
    links = JSON.parse(cli.updated.find { |path, *| path == "a.md" }.last).last
    equal(["(unlinked)", "(unlinked)", state["entries"]["img.png"]["url"]], links)
  end
end

test("accepted dependencies are published and their own links are asked about") do
  repository do |root, state, cli|
    document(root, "a.md", ["b.md"])
    document(root, "b.md", ["c.md", "a.md"])
    document(root, "c.md")
    asked, decide = asker("b.md" => true, "c.md" => false)
    publisher = engine(root, state, cli, only: [(root / "a.md").to_s], decide: decide)
    equal([["a.md", "b.md"], ["b.md", "c.md"]], asked)
    equal(Set["b.md"], publisher.dependencies)
    publish(publisher, root, state)
    equal(["a.md", "b.md"], cli.created.map(&:first).sort)
    equal(["(unlinked)", state["entries"]["a.md"]["url"]],
          JSON.parse(cli.updated.find { |path, *| path == "b.md" }.last).last)
  end
end

test("full sync never asks about dependencies") do
  repository do |root, state, cli|
    document(root, "a.md", ["b.md"])
    document(root, "b.md")
    publish(engine(root, state, cli, decide: ->(*) { raise "asked" }), root, state)
    equal(2, cli.created.size)
  end
end

begin
  require "kramdown"
  require "kramdown-parser-gfm"
  parser_available = true
rescue LoadError
  parser_available = false
end

if parser_available
  test("headings get GitHub-style named anchors") do
    html = Sync::Markdown.new("## 2. Upstream job R: the company's record\n\n## Notes\n\n## Notes\n\n" \
                              "## Q&A -- \"quoted\" ... `code`\n").render({})
    assert(html.include?('<a name="2-upstream-job-r-the-companys-record"></a>'), html)
    assert(html.include?('<a name="notes"></a>') && html.include?('<a name="notes-1"></a>'), html)
    assert(html.include?('<a name="qa----quoted--code"></a>'), html)
  end

  test("task lists render as text; other inputs are still rejected") do
    html = Sync::Markdown.new("- [ ] todo\n- [x] done\n").render({})
    assert(html.include?("\u2610 todo") && html.include?("\u2611 done") && !html.include?("<input"), html)
    raises(Sync::Error) { Sync::Markdown.new('<input type="checkbox">') }
  end

  test("real parser rewrites reference and inline links, preserving code") do
    document = Sync::Markdown.new("[B][ref]\n\n[ref]: b.md \"Title\"\n\n`[code](missing.md)`\n\n```md\n[x](missing.md)\n```\n\n[web](https://example.org)")
    links = []
    document.links do |node, attr|
      links << node.attr[attr]
      node.options[:sync_target] = "b.md" if node.attr[attr] == "b.md"
    end
    equal(["b.md", "https://example.org"], links)
    result = document.render("b.md" => { "url" => "https://3.basecamp.com/1/buckets/2/documents/3" })
    assert(result.include?('title="Title"'))
    assert(result.include?("[code](missing.md)"))
    assert(result.include?("documents/3"))
  end

  test("real parser turns local images into escaped links and is repeatable") do
    document = Sync::Markdown.new("![Diagram & picture](image.png)")
    document.links { |node, _| node.options[:sync_target] = "image.png" }
    entries = { "image.png" => { "url" => "https://3.basecamp.com/1/buckets/2/uploads/3" } }
    rendered = document.render(entries)
    assert(!rendered.include?("<img"))
    assert(rendered.include?("Diagram &amp; picture"))
    equal(rendered, document.render(entries))
  end

  test("real parser rejects raw HTML links") do
    raises(Sync::Error) { Sync::Markdown.new('<a href="missing.md">raw</a>') }
  end

  test("real parser unlinks declined links and images, keeping their text") do
    document = Sync::Markdown.new("See [the *notes*](n.md) and ![Plan](n.md).\n\nNote[^1]\n\n[^1]: In [footnote](n.md).")
    document.links { |node, _| node.options[:sync_unlink] = true }
    rendered = document.render({})
    assert(!rendered.include?("<a href=\"n.md") && !rendered.include?("<img"), rendered)
    assert(rendered.include?("the <em>notes</em>"), rendered)
    assert(rendered.include?("Plan"), rendered)
    assert(rendered.include?("In footnote"), rendered)
  end

  test("command line plans selected files and reports dependency choices") do
    repository do |root, _state, _cli|
      put(root, "a.md", "[B](b.md)")
      put(root, "b.md", "B")
      put(root, "c.md", "C")
      (root / "sync.yml").write("account: 1\nproject: 2\n")
      config = (root / "sync.yml").to_s
      out, err = StringIO.new, StringIO.new
      equal(0, Sync.run(["plan", "--config", config, (root / "a.md").to_s], out: out, err: err))
      equal("ask: b.md (linked from a.md; not on Basecamp yet)\ncreate: a.md\n", out.string)
      out = StringIO.new
      equal(0, Sync.run(["plan", "--with-dependencies", "--config", config, (root / "a.md").to_s], out: out, err: err))
      equal("create: a.md\ncreate (linked dependency): b.md\n", out.string)
      err = StringIO.new
      equal(1, Sync.run(["plan", "--with-dependencies", "--config", config], out: StringIO.new, err: err))
      assert(err.string.include?("--with-dependencies requires FILE arguments"), err.string)
      err = StringIO.new
      equal(1, Sync.run(["sync", "--config", config, (root / "a.md").to_s], out: StringIO.new, err: err, input: StringIO.new("y\n")))
      assert(err.string.include?("--with-dependencies"), err.string)
      assert(!(root / ".basecamp-md-sync-state.json").exist?)
    end
  end

  test("real parser end-to-end circular sync and unchanged rerun") do
    repository do |root, state, cli|
      put(root, "a.md", "[B](b.md)")
      put(root, "b.md", "[A](a.md)")
      2.times { publish(Sync::Publisher.new(root, {}, state, cli).prepare, root, state) }
      equal(2, cli.created.size)
      equal(2, cli.updated.size)
      assert(cli.updated.first.last.include?(state["entries"]["b.md"]["url"]))
    end
  end
else
  $skipped += 8
  puts "SKIP 8 real Markdown parser integration tests: install kramdown and kramdown-parser-gfm"
  if ARGV.include?("--require-parser")
    $failed += 1
    warn "FAIL required parser dependencies are missing"
  end
end

puts "#{$passed} passed, #{$failed} failed, #{$skipped} skipped"
exit($failed.zero? ? 0 : 1)

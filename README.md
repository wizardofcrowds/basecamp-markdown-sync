# Basecamp Markdown Sync

A Ruby tool that publishes Markdown from a Git repository to a Basecamp project's Docs & Files through the installed `basecamp` CLI. Repository links become Basecamp links, without requiring the same folder structure.

Git is the source of truth. The tool reads current working-tree contents, including uncommitted changes, for selected Git-tracked Markdown files.

## Install and run

Requires Ruby 3.1+, Git, and an authenticated Basecamp CLI supporting `files documents create`, `files update`, `files uploads create`, and `files replace`.

Install the two pure Ruby Markdown gems:

```sh
gem install kramdown -v '~> 2.5'
gem install kramdown-parser-gfm -v '~> 1.1'
cp basecamp-sync.example.yml basecamp-sync.yml
```

Edit the YAML configuration: set `repository` to the Git repository root and supply explicit account and project IDs. Optionally set the CLI profile and destination vault. Relative paths are resolved against the configuration file.

```sh
ruby bin/basecamp-md-sync plan --config basecamp-sync.yml
ruby bin/basecamp-md-sync sync --config basecamp-sync.yml
```

`plan` validates local links and lists documents and referenced assets without contacting Basecamp. Existing entries are compared during `sync`; the plan does not inspect remote edits.

### Publishing selected files

Name one or more documents to publish only those (paths are relative to the current directory):

```sh
basecamp-md-sync sync docs/guide.md
basecamp-md-sync sync --with-dependencies docs/guide.md docs/faq.md
```

Named files must be Git-tracked Markdown selected by `include`/`exclude`. Their referenced assets are uploaded as usual. Links to other documents already on Basecamp (recorded in the state file) use their existing URLs; those documents are not updated.

For each linked document that is not on Basecamp yet, `sync` asks whether to upload it too. Answering yes publishes it and asks about its own links in turn. Answering no (the default) publishes the link as plain text, so no repository path reaches Basecamp; a later run that publishes that document does not fix the link until the linking document is synced again. `--with-dependencies` answers yes to every question; it requires file arguments, since a full sync already publishes every selected document. Without a terminal to ask on, `sync` stops before writing anything unless `--with-dependencies` is given. `plan` never asks; it lists each undecided document as `ask:`.

Links to excluded or untracked Markdown still stop the run, as in a full sync.

To install the command on your PATH instead of running it from this directory:

```sh
gem build basecamp-markdown-sync.gemspec
gem install ./basecamp-markdown-sync-0.3.0.gem
basecamp-md-sync --help
```

A Gemfile is also provided for Bundler users. There is no Python dependency. The Ruby version uses YAML configuration; the earlier prototype's TOML configuration must be converted. Its JSON state format is retained when repository and destination settings match.

## Sync behavior

- Selects tracked `.md` documents with include/exclude globs. Uses repository-relative paths as document titles to distinguish identical filenames, and publishes into one destination vault.
- Parses Markdown with Kramdown's GFM parser. Rewrites inline links, reference links, and images without modifying links inside code examples. External links stay unchanged. Kramdown GFM is not a promise of exact GitHub rendering.
- Creates all destinations before rendering final document contents. This supports forward and circular links. Newly created documents briefly show a placeholder. Document creation uses `--no-subscribe`.
- Uploads referenced local assets, even if those assets are untracked. Local images become labeled links to uploads, rather than inline images. Only reference assets you intend to publish.
- Treats `/path` as relative to the repository root. Rejects missing files, symlinks or paths outside the repository, and links to excluded/untracked Markdown documents.
- Warns and removes query strings and heading fragments from local links, including same-document anchors. Basecamp heading anchors are not assumed compatible with GitHub anchors.
- Renders HTML locally and submits it with `--format html`. Source HTML is rejected before any writes because its links would bypass Markdown link rewriting. Use Markdown links/images instead. MDX, wiki links and YAML front matter are not supported specially. Rendering of tables, task lists, and other rich text ultimately depends on Basecamp's supported HTML.
- Saves IDs, URLs and content hashes atomically after successful operations. Skips unchanged rendered content. Updated files use `files replace`, preserving URLs and comments.
- Does not delete Basecamp items when local files disappear. Renames create new items; old items remain. It does not inspect remote edits, restore deleted remote items, or merge concurrent edits.

Basecamp edits are overwritten when the corresponding rendered local document changes. If only a remote edit changes, an otherwise unchanged local document is skipped.

## State and recovery

Keep the JSON state file between runs and back it up. Separate repositories or destinations need separate state files. State is bound to the repository path, account, project, vault, and CLI profile. A local file lock prevents overlapping runs using the same state file on Linux/macOS.

Before creating an item, the tool records a `pending_create` marker. If the response or state save is lost, reruns stop to avoid creating a duplicate. Inspect Basecamp for the path/title:

- If nothing was created, remove `pending_create` from the state JSON.
- If an item exists, add its `{"id": 123, "url": "https://3.basecamp.com/..."}` under `entries["path/to/file"]`, then remove the marker. Leave its hash absent so the next run updates its content.

No automatic retries are made. Successfully saved creations and interrupted document updates can be resumed by rerunning `sync`.

The tool runs `basecamp instructions` before writes. If configured instructions exist, it stops and prints them for operator review; it cannot interpret arbitrary natural-language publishing policies. The CLI's default visibility applies unless the destination folder determines visibility.

Add `.basecamp-md-sync-state.json*` to the source repository's `.gitignore`. Authentication remains in the Basecamp CLI; the tool does not read credential files.

## Tests

```sh
ruby test/run.rb
```

The standard-library runner tests CLI invocation, state persistence, link resolution, incremental updates, circular links, and recovery in temporary Git repositories using a fake Basecamp client. Six additional integration tests exercise the real Markdown parser when the gems are installed; otherwise they are explicitly reported as skipped. To require those tests (for example in CI):

```sh
ruby test/run.rb --require-parser
```

Tests never write to a Basecamp project.

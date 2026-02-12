# Apple Mail MCP Server

An MCP server for Apple Mail.app via AppleScript. Built with the [mcp](https://github.com/modelcontextprotocol/ruby-sdk) Ruby gem, stdio transport.

## Requirements

- macOS with Mail.app configured
- Ruby >= 3.4
- Bundler

## Installation

```bash
git clone https://github.com/your-username/apple-mail-mcp-ruby.git
cd apple-mail-mcp-ruby
bundle install
```

## Setup

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "apple-mail": {
      "command": "ruby",
      "args": ["/absolute/path/to/apple-mail-mcp-ruby/server.rb"]
    }
  }
}
```

Replace the path with the actual location of `server.rb`.

Restart Claude Desktop after saving.

### Claude Code

```bash
claude mcp add apple-mail -- ruby /absolute/path/to/apple-mail-mcp-ruby/server.rb
```

### Ruby version managers

If Ruby is installed via mise, rbenv, asdf, etc., the app may not find `ruby` in PATH. Use the full path instead:

```bash
# Find your Ruby path:
which ruby
```

Then use it as the command:

```json
{
  "mcpServers": {
    "apple-mail": {
      "command": "/Users/you/.local/share/mise/installs/ruby/3.4.8/bin/ruby",
      "args": ["/absolute/path/to/apple-mail-mcp-ruby/server.rb"]
    }
  }
}
```

## macOS permissions

On first use, macOS will ask to allow controlling Mail.app. If the prompt doesn't appear or was dismissed, grant it manually:

**System Settings > Privacy & Security > Automation** — allow your app (Claude Desktop, Terminal, etc.) to control **Mail.app**.

All tools will fail without this permission.

## Verify

Check that the server starts and responds:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | bundle exec ruby server.rb
```

You should see a JSON response containing `"serverInfo":{"name":"apple-mail","version":"1.0.0"}`.

## Tools

### list_accounts

List all email accounts in Mail.app.

### list_mailboxes

List mailboxes for an account.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `account` | yes | Account name |

### get_unread_count

Get unread count for a mailbox.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `account` | yes | Account name |
| `mailbox` | yes | Mailbox name |

### search_emails

Search emails with filters. Defaults to INBOX of all accounts. Returns up to 50 results.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `account` | no | Search in this account |
| `mailbox` | no | Search in this mailbox |
| `subject_contains` | no | Filter by subject text |
| `sender_contains` | no | Filter by sender text |
| `is_read` | no | Filter by read status (true/false) |
| `date_from` | no | Start date (YYYY-MM-DD) |
| `date_to` | no | End date (YYYY-MM-DD) |

### read_email

Read full email content by message ID.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_id` | yes | RFC message ID |
| `account` | no | Account name (speeds up lookup) |
| `mailbox` | no | Mailbox name (speeds up lookup) |

### mark_read

Mark emails as read.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_ids` | yes | Array of RFC message IDs |
| `account` | no | Account name (speeds up lookup) |
| `mailbox` | no | Mailbox name (speeds up lookup) |

### mark_unread

Mark emails as unread.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_ids` | yes | Array of RFC message IDs |
| `account` | no | Account name (speeds up lookup) |
| `mailbox` | no | Mailbox name (speeds up lookup) |

### mark_flagged

Flag or unflag emails.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_ids` | yes | Array of RFC message IDs |
| `flagged` | yes | true to flag, false to unflag |
| `account` | no | Account name (speeds up lookup) |
| `mailbox` | no | Mailbox name (speeds up lookup) |

### move_email

Move an email to a different mailbox.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_id` | yes | RFC message ID |
| `to_mailbox` | yes | Destination mailbox |
| `to_account` | yes | Destination account |
| `account` | no | Source account (speeds up lookup) |
| `mailbox` | no | Source mailbox (speeds up lookup) |

### trash_email

Move an email to trash.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `message_id` | yes | RFC message ID |
| `account` | no | Account name (speeds up lookup) |
| `mailbox` | no | Mailbox name (speeds up lookup) |

## License

MIT

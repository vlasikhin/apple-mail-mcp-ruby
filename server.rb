require "mcp"
require "json"
require "open3"

module AppleMail
  module_function

  def sanitize(str)
    str.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
  end

  def run_applescript(script)
    stdout, stderr, status = Open3.capture3("osascript", stdin_data: script)
    unless status.success?
      msg = stderr.strip.sub(/^.*?execution error: /, "").sub(/\(-?\d+\)\s*$/, "").strip
      raise msg.empty? ? "AppleScript execution failed" : msg
    end
    stdout.strip
  end

  def success_response(data)
    MCP::Tool::Response.new([{type: "text", text: JSON.generate(data)}])
  end

  def error_response(message)
    MCP::Tool::Response.new([{type: "text", text: JSON.generate({error: message})}], error: true)
  end

  def build_date_script(date_string, var_name, end_of_day: false)
    parts = date_string.split("-").map(&:to_i)
    year, month, day = parts
    h, m, s = end_of_day ? [23, 59, 59] : [0, 0, 0]
    <<~AS
      set #{var_name} to current date
      set year of #{var_name} to #{year}
      set month of #{var_name} to #{month}
      set day of #{var_name} to #{day}
      set hours of #{var_name} to #{h}
      set minutes of #{var_name} to #{m}
      set seconds of #{var_name} to #{s}
    AS
  end

  def parse_tsv(output, fields)
    return [] if output.empty?
    output.split("\n").map do |line|
      values = line.split("\t", fields.length)
      fields.each_with_index.with_object({}) do |(field, i), hash|
        hash[field] = values[i]&.strip
      end
    end
  end

  def find_message(message_id, account: nil, mailbox: nil)
    safe_id = sanitize(message_id)

    if account && mailbox
      safe_acct = sanitize(account)
      safe_mbox = sanitize(mailbox)
      script = <<~AS
        tell application "Mail"
          set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
          if (count of msgs) > 0 then
            return "found"
          end if
        end tell
      AS
      result = run_applescript(script)
      if result.include?("found")
        return [account, mailbox]
      else
        raise "Message not found in #{mailbox} of #{account}"
      end
    end

    script = <<~AS
      tell application "Mail"
        set acctList to every account
        repeat with acct in acctList
          set mboxes to every mailbox of acct
          repeat with mbox in mboxes
            try
              set msgs to (messages of mbox whose message id is "#{safe_id}")
              if (count of msgs) > 0 then
                return (name of acct) & "\t" & (name of mbox)
              end if
            end try
          end repeat
        end repeat
      end tell
    AS
    result = run_applescript(script)
    raise "Message not found" if result.empty?
    parts = result.split("\t", 2)
    [parts[0], parts[1]]
  end
end

class ListAccounts < MCP::Tool
  description "List all email accounts configured in Apple Mail"

  class << self
    def call
      script = <<~AS
        tell application "Mail"
          set output to ""
          set acctList to every account
          repeat with acct in acctList
            set acctName to name of acct
            set acctType to account type of acct as string
            set addrs to email addresses of acct
            set addrStr to ""
            repeat with a in addrs
              if addrStr is not "" then set addrStr to addrStr & ", "
              set addrStr to addrStr & a
            end repeat
            set output to output & acctName & "\t" & acctType & "\t" & addrStr & "\n"
          end repeat
          return output
        end tell
      AS
      result = AppleMail.run_applescript(script)
      accounts = AppleMail.parse_tsv(result, [:name, :type, :email_addresses])
      accounts.each { |a| a[:email_addresses] = a[:email_addresses].to_s.split(", ") }
      AppleMail.success_response(accounts: accounts)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class ListMailboxes < MCP::Tool
  description "List all mailboxes for a given email account"

  input_schema({
    properties: {
      account: {type: "string", description: "Account name"}
    },
    required: ["account"]
  })

  class << self
    def call(account:)
      safe_acct = AppleMail.sanitize(account)
      script = <<~AS
        tell application "Mail"
          set output to ""
          set mboxes to every mailbox of account "#{safe_acct}"
          repeat with mbox in mboxes
            set mboxName to name of mbox
            set unread to unread count of mbox
            set output to output & mboxName & "\t" & unread & "\n"
          end repeat
          return output
        end tell
      AS
      result = AppleMail.run_applescript(script)
      mailboxes = AppleMail.parse_tsv(result, [:name, :unread_count])
      mailboxes.each { |m| m[:unread_count] = m[:unread_count].to_i }
      AppleMail.success_response(account: account, mailboxes: mailboxes)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class GetUnreadCount < MCP::Tool
  description "Get the unread message count for a specific mailbox"

  input_schema({
    properties: {
      account: {type: "string", description: "Account name"},
      mailbox: {type: "string", description: "Mailbox name"}
    },
    required: ["account", "mailbox"]
  })

  class << self
    def call(account:, mailbox:)
      safe_acct = AppleMail.sanitize(account)
      safe_mbox = AppleMail.sanitize(mailbox)
      script = <<~AS
        tell application "Mail"
          return unread count of mailbox "#{safe_mbox}" of account "#{safe_acct}"
        end tell
      AS
      result = AppleMail.run_applescript(script)
      AppleMail.success_response(account: account, mailbox: mailbox, unread_count: result.to_i)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class SearchEmails < MCP::Tool
  description "Search for emails with optional filters. Defaults to INBOX of all accounts. Returns up to 50 results."

  input_schema({
    properties: {
      account: {type: "string", description: "Account name to search in"},
      mailbox: {type: "string", description: "Mailbox name to search in"},
      subject_contains: {type: "string", description: "Filter by subject containing this text"},
      sender_contains: {type: "string", description: "Filter by sender containing this text"},
      is_read: {type: "boolean", description: "Filter by read status"},
      date_from: {type: "string", description: "Filter emails from this date (YYYY-MM-DD)"},
      date_to: {type: "string", description: "Filter emails up to this date (YYYY-MM-DD)"}
    }
  })

  class << self
    def call(account: nil, mailbox: nil, subject_contains: nil, sender_contains: nil, is_read: nil, date_from: nil, date_to: nil)
      whose_clauses = []
      if subject_contains
        whose_clauses << "subject contains \"#{AppleMail.sanitize(subject_contains)}\""
      end
      if sender_contains
        whose_clauses << "sender contains \"#{AppleMail.sanitize(sender_contains)}\""
      end
      unless is_read.nil?
        whose_clauses << "read status is #{is_read}"
      end
      whose = whose_clauses.empty? ? "" : " whose #{whose_clauses.join(" and ")}"

      date_setup = ""
      date_filter = ""
      if date_from
        date_setup += AppleMail.build_date_script(date_from, "dateFrom")
        date_filter += " and date received of msg >= dateFrom"
      end
      if date_to
        date_setup += AppleMail.build_date_script(date_to, "dateTo", end_of_day: true)
        date_filter += " and date received of msg <= dateTo"
      end
      if date_filter != ""
        date_filter = date_filter.sub(/^ and /, "")
      end

      mailbox_expr = if account && mailbox
        "mailbox \"#{AppleMail.sanitize(mailbox)}\" of account \"#{AppleMail.sanitize(account)}\""
      else
        nil
      end

      if mailbox_expr
        script = build_search_script(mailbox_expr, "acctName", "mboxName", whose, date_setup, date_filter, account, mailbox)
      else
        target_mailbox = mailbox || "INBOX"
        safe_mbox = AppleMail.sanitize(target_mailbox)
        script = <<~AS
          tell application "Mail"
            #{date_setup}
            set output to ""
            set msgCount to 0
            set acctList to every account
            repeat with acct in acctList
              #{account ? "if name of acct is \"#{AppleMail.sanitize(account)}\" then" : ""}
              try
                set mbox to mailbox "#{safe_mbox}" of acct
                set msgs to (every message of mbox#{whose})
                set acctName to name of acct
                repeat with msg in msgs
                  if msgCount >= 50 then exit repeat
                  set dateStr to date received of msg as string
                  #{date_filter.empty? ? "" : "if #{date_filter} then"}
                  set mid to message id of msg
                  set subj to subject of msg
                  set sndr to sender of msg
                  set isRead to read status of msg
                  set output to output & mid & "\t" & subj & "\t" & sndr & "\t" & dateStr & "\t" & isRead & "\t" & "#{safe_mbox}" & "\t" & acctName & "\n"
                  set msgCount to msgCount + 1
                  #{date_filter.empty? ? "" : "end if"}
                end repeat
              end try
              if msgCount >= 50 then exit repeat
              #{account ? "end if" : ""}
            end repeat
            return output
          end tell
        AS
      end

      result = AppleMail.run_applescript(script)
      fields = [:message_id, :subject, :sender, :date, :is_read, :mailbox, :account]
      messages = AppleMail.parse_tsv(result, fields)
      messages.each { |m| m[:is_read] = m[:is_read] == "true" }
      AppleMail.success_response(messages: messages, count: messages.length)
    rescue => e
      AppleMail.error_response(e.message)
    end

    private

    def build_search_script(mailbox_expr, _acct_var, _mbox_var, whose, date_setup, date_filter, account, mailbox)
      <<~AS
        tell application "Mail"
          #{date_setup}
          set output to ""
          set msgCount to 0
          set msgs to (every message of #{mailbox_expr}#{whose})
          repeat with msg in msgs
            if msgCount >= 50 then exit repeat
            set dateStr to date received of msg as string
            #{date_filter.empty? ? "" : "if #{date_filter} then"}
            set mid to message id of msg
            set subj to subject of msg
            set sndr to sender of msg
            set isRead to read status of msg
            set output to output & mid & "\t" & subj & "\t" & sndr & "\t" & dateStr & "\t" & isRead & "\t" & "#{AppleMail.sanitize(mailbox)}" & "\t" & "#{AppleMail.sanitize(account)}" & "\n"
            set msgCount to msgCount + 1
            #{date_filter.empty? ? "" : "end if"}
          end repeat
          return output
        end tell
      AS
    end
  end
end

class ReadEmail < MCP::Tool
  description "Read the full content of an email by message ID"

  input_schema({
    properties: {
      message_id: {type: "string", description: "RFC message ID"},
      account: {type: "string", description: "Account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Mailbox name (speeds up lookup)"}
    },
    required: ["message_id"]
  })

  class << self
    def call(message_id:, account: nil, mailbox: nil)
      acct, mbox = AppleMail.find_message(message_id, account: account, mailbox: mailbox)
      safe_id = AppleMail.sanitize(message_id)
      safe_acct = AppleMail.sanitize(acct)
      safe_mbox = AppleMail.sanitize(mbox)
      script = <<~AS
        tell application "Mail"
          set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
          set msg to item 1 of msgs
          set subj to subject of msg
          set sndr to sender of msg
          set dateStr to date received of msg as string
          set isRead to read status of msg
          set isFlagged to flagged status of msg
          set toList to ""
          set toRecips to to recipients of msg
          repeat with r in toRecips
            if toList is not "" then set toList to toList & ", "
            set toList to toList & (address of r) as string
          end repeat
          set ccList to ""
          set ccRecips to cc recipients of msg
          repeat with r in ccRecips
            if ccList is not "" then set ccList to ccList & ", "
            set ccList to ccList & (address of r) as string
          end repeat
          set body to content of msg
          return subj & "\t" & sndr & "\t" & toList & "\t" & ccList & "\t" & dateStr & "\t" & isRead & "\t" & isFlagged & "\t" & body
        end tell
      AS
      result = AppleMail.run_applescript(script)
      fields = [:subject, :sender, :to, :cc, :date, :is_read, :is_flagged, :body]
      values = result.split("\t", fields.length)
      email = fields.each_with_index.with_object({}) do |(field, i), hash|
        hash[field] = values[i]
      end
      email[:to] = email[:to].to_s.split(", ")
      email[:cc] = email[:cc].to_s.split(", ")
      email[:is_read] = email[:is_read]&.strip == "true"
      email[:is_flagged] = email[:is_flagged]&.strip == "true"
      email[:message_id] = message_id
      email[:account] = acct
      email[:mailbox] = mbox
      AppleMail.success_response(email: email)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class MarkRead < MCP::Tool
  description "Mark one or more emails as read"

  input_schema({
    properties: {
      message_ids: {type: "array", items: {type: "string"}, description: "Array of RFC message IDs"},
      account: {type: "string", description: "Account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Mailbox name (speeds up lookup)"}
    },
    required: ["message_ids"]
  })

  class << self
    def call(message_ids:, account: nil, mailbox: nil)
      results = message_ids.map do |mid|
        acct, mbox = AppleMail.find_message(mid, account: account, mailbox: mailbox)
        safe_id = AppleMail.sanitize(mid)
        safe_acct = AppleMail.sanitize(acct)
        safe_mbox = AppleMail.sanitize(mbox)
        script = <<~AS
          tell application "Mail"
            set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
            repeat with msg in msgs
              set read status of msg to true
            end repeat
          end tell
        AS
        AppleMail.run_applescript(script)
        {message_id: mid, status: "marked_read"}
      end
      AppleMail.success_response(results: results)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class MarkUnread < MCP::Tool
  description "Mark one or more emails as unread"

  input_schema({
    properties: {
      message_ids: {type: "array", items: {type: "string"}, description: "Array of RFC message IDs"},
      account: {type: "string", description: "Account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Mailbox name (speeds up lookup)"}
    },
    required: ["message_ids"]
  })

  class << self
    def call(message_ids:, account: nil, mailbox: nil)
      results = message_ids.map do |mid|
        acct, mbox = AppleMail.find_message(mid, account: account, mailbox: mailbox)
        safe_id = AppleMail.sanitize(mid)
        safe_acct = AppleMail.sanitize(acct)
        safe_mbox = AppleMail.sanitize(mbox)
        script = <<~AS
          tell application "Mail"
            set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
            repeat with msg in msgs
              set read status of msg to false
            end repeat
          end tell
        AS
        AppleMail.run_applescript(script)
        {message_id: mid, status: "marked_unread"}
      end
      AppleMail.success_response(results: results)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class MarkFlagged < MCP::Tool
  description "Flag or unflag one or more emails"

  input_schema({
    properties: {
      message_ids: {type: "array", items: {type: "string"}, description: "Array of RFC message IDs"},
      flagged: {type: "boolean", description: "true to flag, false to unflag"},
      account: {type: "string", description: "Account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Mailbox name (speeds up lookup)"}
    },
    required: ["message_ids", "flagged"]
  })

  class << self
    def call(message_ids:, flagged:, account: nil, mailbox: nil)
      results = message_ids.map do |mid|
        acct, mbox = AppleMail.find_message(mid, account: account, mailbox: mailbox)
        safe_id = AppleMail.sanitize(mid)
        safe_acct = AppleMail.sanitize(acct)
        safe_mbox = AppleMail.sanitize(mbox)
        script = <<~AS
          tell application "Mail"
            set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
            repeat with msg in msgs
              set flagged status of msg to #{flagged}
            end repeat
          end tell
        AS
        AppleMail.run_applescript(script)
        {message_id: mid, status: flagged ? "flagged" : "unflagged"}
      end
      AppleMail.success_response(results: results)
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class MoveEmail < MCP::Tool
  description "Move an email to a different mailbox"

  input_schema({
    properties: {
      message_id: {type: "string", description: "RFC message ID"},
      to_mailbox: {type: "string", description: "Destination mailbox name"},
      to_account: {type: "string", description: "Destination account name"},
      account: {type: "string", description: "Source account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Source mailbox name (speeds up lookup)"}
    },
    required: ["message_id", "to_mailbox", "to_account"]
  })

  class << self
    def call(message_id:, to_mailbox:, to_account:, account: nil, mailbox: nil)
      acct, mbox = AppleMail.find_message(message_id, account: account, mailbox: mailbox)
      safe_id = AppleMail.sanitize(message_id)
      safe_acct = AppleMail.sanitize(acct)
      safe_mbox = AppleMail.sanitize(mbox)
      safe_to_mbox = AppleMail.sanitize(to_mailbox)
      safe_to_acct = AppleMail.sanitize(to_account)
      script = <<~AS
        tell application "Mail"
          set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
          set msg to item 1 of msgs
          move msg to mailbox "#{safe_to_mbox}" of account "#{safe_to_acct}"
        end tell
      AS
      AppleMail.run_applescript(script)
      AppleMail.success_response(message_id: message_id, moved_to: {account: to_account, mailbox: to_mailbox})
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

class TrashEmail < MCP::Tool
  description "Move an email to the trash"

  input_schema({
    properties: {
      message_id: {type: "string", description: "RFC message ID"},
      account: {type: "string", description: "Account name (speeds up lookup)"},
      mailbox: {type: "string", description: "Mailbox name (speeds up lookup)"}
    },
    required: ["message_id"]
  })

  class << self
    def call(message_id:, account: nil, mailbox: nil)
      acct, mbox = AppleMail.find_message(message_id, account: account, mailbox: mailbox)
      safe_id = AppleMail.sanitize(message_id)
      safe_acct = AppleMail.sanitize(acct)
      safe_mbox = AppleMail.sanitize(mbox)
      script = <<~AS
        tell application "Mail"
          set msgs to (messages of mailbox "#{safe_mbox}" of account "#{safe_acct}" whose message id is "#{safe_id}")
          set msg to item 1 of msgs
          delete msg
        end tell
      AS
      AppleMail.run_applescript(script)
      AppleMail.success_response(message_id: message_id, status: "trashed")
    rescue => e
      AppleMail.error_response(e.message)
    end
  end
end

server = MCP::Server.new(
  name: "apple-mail",
  version: "1.0.0",
  tools: [ListAccounts, ListMailboxes, GetUnreadCount, SearchEmails,
    ReadEmail, MarkRead, MarkUnread, MarkFlagged, MoveEmail, TrashEmail]
)
MCP::Server::Transports::StdioTransport.new(server).open

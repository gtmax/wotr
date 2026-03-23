# Icon Selection Guide

## The VS-16 Rule

**Never use emoji that require U+FE0F (Variation Selector 16) to be 2 columns wide.**

VS-16 emoji cause rendering artifacts when ratatui's diff-based terminal update applies the row selection highlight. The continuation cell (second column) is skipped during diff rendering, leaving its background un-updated — the icon disappears and the highlight bar overflows.

### How to Tell

An emoji has VS-16 if its raw bytes include `\xEF\xB8\x8F` (UTF-8 encoding of U+FE0F). In practice, these are older emoji from the Miscellaneous Symbols range (U+1F5xx) that need VS-16 to trigger emoji presentation.

### Bad (VS-16 required, width 1 without it)

| Emoji | Name | Codepoints |
|-------|------|------------|
| 🖥️ | Desktop Computer | U+1F5A5 + U+FE0F |
| 🗄️ | File Cabinet | U+1F5C4 + U+FE0F |
| 🗃️ | Card File Box | U+1F5C3 + U+FE0F |
| 🖨️ | Printer | U+1F5A8 + U+FE0F |
| 🗂️ | Card Index Dividers | U+1F5C2 + U+FE0F |
| 🖱️ | Computer Mouse | U+1F5B1 + U+FE0F |
| ⚙️ | Gear | U+2699 + U+FE0F |
| 🛡️ | Shield | U+1F6E1 + U+FE0F |

### Good (natively 2-wide, no VS-16 needed)

| Emoji | Name | Good for |
|-------|------|----------|
| 💻 | Laptop | Web servers, dev servers |
| 💾 | Floppy Disk | Databases, persistence |
| 🧪 | Test Tube | Test servers, CI |
| 🤖 | Robot | AI agents, bots, automation |
| 📊 | Bar Chart | Analytics, dashboards |
| 📁 | File Folder | File-based resources |
| 🌐 | Globe | Network services, APIs |
| 🔧 | Wrench | Build tools, compilers |
| 📦 | Package | Package managers, registries |
| 🐳 | Whale | Docker containers |
| 🔥 | Fire | Hot reload, live services |
| 📡 | Satellite | Message queues, pub/sub |
| 🔑 | Key | Auth services, vaults |
| 📬 | Mailbox | Email, notifications |
| 🗺 | Map | Routing, DNS |
| 🏗 | Construction | Infrastructure, IaC |
| ⚡ | Lightning | Fast/real-time services |
| 🧩 | Puzzle Piece | Plugins, extensions |
| 📝 | Memo | Logs, documentation |
| 🛒 | Shopping Cart | E-commerce, payments |

### Validation

Test in Ruby before committing:

```ruby
require 'ratatui_ruby'
icon = "💻"
w = RatatuiRuby._text_width(icon)
has_vs = icon.include?("\uFE0F")
puts "#{icon} width=#{w} vs=#{has_vs}"
# Must be: width=2, vs=false
```

### Choosing Icons

1. Pick an emoji that visually represents the resource
2. Verify it's natively 2-wide (no VS-16)
3. Ensure it's distinct from other resource icons in the same config
4. Each resource gets a keyboard shortcut from its name — the icon just provides visual identification

<!--
RASCUNHO para https://bugs.ruby-lang.org/projects/ruby-master/issues/new
Tracker: Bug | Assunto: a linha "Subject" abaixo | ruby -v: a linha do 4.1.0dev
Revise e publique pela sua conta.
Este comentário não deve ser colado.
-->

**Subject:** Segfault in `Thread::Backtrace::Location#syntax_tree` (via `Exception#detailed_message` / error_highlight) when called from multiple Ractors

**ruby -v:** ruby 4.1.0dev (2026-10-14T14:33:24Z master b709bdb3e3) +PRISM [x86_64-linux]

---

Calling `Exception#detailed_message` concurrently from two or more Ractors crashes the VM with
`[BUG] Segmentation fault` on 4.1.0-preview1 and current master. The same script works on 4.0.6
and 4.0.7.

### Reproduction

No gems are involved; error_highlight is loaded by default.

```ruby
n = Integer(ARGV[0] || 2)
rs = Array.new(n) do |i|
  Ractor.new(i) do |id|
    500.times do |k|
      begin
        raise ArgumentError, "falha #{id}-#{k}"
      rescue => e
        e.detailed_message(highlight: false)
      end
    end
    :ok
  end
end
p rs.map(&:value)
```

```
$ ruby repro.rb
<internal:ast>:374: [BUG] Segmentation fault at 0x0000000000000030
```

| Version | Result |
|---|---|
| 4.0.6, 4.0.7 | `[:ok, :ok]` (8/8 runs) |
| 4.1.0-preview1 (2d08b5f42f) | segfault in 4/4 runs with 2 Ractors and 8/8 with 8 Ractors; no crash with 1 Ractor |
| 4.1.0dev master (b709bdb3e3) | segfault 6/6 |

### Backtrace (master)

```
<internal:ast>:374: [BUG] Segmentation fault at 0x0000000000000030
-- Ruby level backtrace information ----------------------------------------
repro.rb:8:in 'detailed_message'
.../lib/ruby/4.1.0+5/error_highlight/core_ext.rb:43:in 'detailed_message'
.../lib/ruby/4.1.0+5/error_highlight/core_ext.rb:34:in 'generate_snippet'
.../lib/ruby/4.1.0+5/error_highlight/base.rb:57:in 'spot'
.../lib/ruby/4.1.0+5/error_highlight/base.rb:77:in 'find_node_from_loc'
<internal:ast>:478:in 'syntax_tree'
<internal:ast>:374:in 'syntax_tree'

-- C level backtrace information -------------------------------------------
rb_vm_bugreport
rb_ec_ractor_ptr / rb_current_execution_context / rb_current_ractor_raw / rb_current_ractor
vm_ic_update
rb_vm_opt_getconstant_path
vm_exec_core
rb_vm_exec
thread_start_func_2
```

The full output is attached (`crash-output-master.txt`).

### Additional observations

1. **The crash is reachable without error_highlight.** Calling
   `e.backtrace_locations.first.syntax_tree` inside `rescue` in 2 Ractors gives the same crash and
   stack. It crashed 1/3 runs on master and 0/3 on preview1, so the `detailed_message` script above
   is the more reliable reproducer.
2. **Some things that look similar do not crash.**
   - `caller_locations(0, 1).first.syntax_tree` in 2 Ractors works.
   - `Ruby::Prism.parse("1 + 1")` in 2 Ractors works.

   So the problem seems specific to backtrace locations taken from an exception, while the
   constant cache in `ast.rb` is updated from a non-main Ractor.
3. **With a single Ractor there is no crash, but error_highlight output regresses.** Inside the
   Ractor, `detailed_message` returns only the message, without the snippet:

   ```ruby
   r = Ractor.new do
     begin
       nil.upcase
     rescue => e
       e.detailed_message(highlight: false)
     end
   end
   puts r.value
   # 4.0.7:  undefined method 'upcase' for nil (NoMethodError)\n\n    nil.upcase\n       ^^^^^^^
   # 4.1:    undefined method 'upcase' for nil (NoMethodError)
   ```

   On 4.1 the snippet is still shown in the main Ractor.
4. **This is easy to hit in practice.** Any library that logs exceptions with `detailed_message`
   from inside Ractors can crash the process. I found it with the `async` gem, whose task-failure
   logging (via the `console` gem) calls `detailed_message`, running one reactor per Ractor. On
   4.0.6 that same setup hangs instead of crashing; I have not diagnosed the 4.0.6 hang.

### Related (but different) issues

- #22386: segfault when a Ractor helper thread reports an exception during teardown. It was
  fixed before preview1, and this still reproduces on preview1 and master.
- #21183: error_highlight raising `Ractor::IsolationError` in non-main Ractors (fixed in 2025).

### Environment and context

- Linux x86_64 (kernel 7.2, AMD Ryzen 7 5700U, 8C/16T). Also seen on Ubuntu 24.04, AMD EPYC
  Genoa (KVM).
- These scripts come out of a benchmark study comparing threads, Ractors and Fibers on Ruby 4.0 and
  4.1. The code, raw results and other Ractor findings (I/O concurrency cap on 4.0.x, socket hangs
  on 4.0.x) are public at: https://github.com/amalrik/ruby-ractors-study. The reproducers for this issue are in
  `upstream/ruby-4.1-detailed-message-ractors/`.

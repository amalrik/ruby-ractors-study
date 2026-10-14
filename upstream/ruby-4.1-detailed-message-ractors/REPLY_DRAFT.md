Thank you for the quick analysis and for splitting the ticket!

Yes, I'm using GCC 16. Both 4.1 builds I reported were compiled locally on Arch Linux:

```
ruby 4.1.0preview1 (2026-10-11 master 2d08b5f42f) +PRISM [x86_64-linux]
ruby 4.1.0dev (2026-10-14T14:33:24Z master b709bdb3e3) +PRISM [x86_64-linux]
CC: gcc (GCC) 16.2.1 20260810, optflags -O3 -fno-fast-math
```

Two corrections to my original report, sorry about them:

- The "Also seen on Ubuntu 24.04, AMD EPYC Genoa" line was wrong. I never ran this reproducer on that machine.
- The 4.0.6/4.0.7 binaries I used as the "works" baseline were prebuilt with GCC 10. So the version comparison in the report is confounded by the compiler, which is consistent with your finding.

I tested both patches applied together: https://github.com/ruby/ruby/pull/19348 and https://github.com/ruby/ruby/pull/19352, cherry-picked onto master 3d168b1. I built with the same GCC 16.2.1 and ran each script N times:

| Script | master b709bdb3e3 (no patches) | master 3d168b1 + both patches |
|---|---|---|
| #22440 reproducer (autoload constant from 8 Ractors) | 10/10 SEGV | 10/10 ok |
| #22439 `detailed_message` from 2 Ractors | 10/10 SEGV | 10/10 ok |
| #22439 `e.backtrace_locations.first.syntax_tree` from 2 Ractors | 1/10 SEGV | 10/10 ok |
| #22442 snippet present in both Ractors (`nil.upcase` in 2 Ractors) | not testable (SEGV) | 5/5 runs, snippet in both |

So with both patches, everything in this ticket is fixed on my machine. Thanks!

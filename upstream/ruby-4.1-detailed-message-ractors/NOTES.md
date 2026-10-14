# Notas: segfault em Ractors via error_highlight / Location#syntax_tree (Ruby 4.1)

Verificado em 2026-10-14, Linux x86_64.

| Ruby | `repro.rb` (detailed_message, 2 Ractors) | `repro_syntax_tree.rb` |
|---|---|---|
| 4.0.6 / 4.0.7 | ok (8/8) | método não existe |
| 4.1.0-preview1 (2d08b5f42f) | segfault 4/4 (2 Ractors), 8/8 (8 Ractors); 0/4 com 1 Ractor | 0/3 |
| 4.1.0dev master (b709bdb3e3, 2026-10-14) | segfault 6/6 | 1/3 |

- Pilha: `error_highlight` → `Thread::Backtrace::Location#syntax_tree`
  (`<internal:ast>:478`) → `<internal:ast>:374` → `vm_ic_update` →
  `rb_current_ractor` → SEGV no endereço 0x30.
- Com **1** Ractor não cai, mas o `error_highlight` **perde o trecho
  destacado** dentro do Ractor na 4.1. Na 4.0.7 o trecho aparece. É uma
  regressão funcional mesmo sem o crash (`highlight_lost.rb`).
- `Ruby::Prism.parse` direto em 2 Ractors: ok. `caller_locations(...).first.syntax_tree`
  em 2 Ractors: ok. Só cai com a localização vinda de uma exceção.
- Relacionados, mas diferentes:
  - Bug #22386: segfault no encerramento de Ractor, ao reportar exceção.
    Fechado; corrigido em 13411f495b no master antes da preview1.
  - Bug #21183: `error_highlight` em Ractors não-principais
    (IsolationError/UnsafeError). Fechado em 2025.
- Busca feita no bugs.ruby-lang.org e no GitHub ruby/ruby: nenhum relato do
  mesmo crash encontrado.

## Atualização (2026-10-14): resposta do time do Ruby

- O crash só reproduz com **GCC 16**. As nossas builds da 4.1 usaram o GCC 16.2.1; a 4.0.7 de
  comparação era um binário pronto compilado com o GCC 10, então a coluna "4.0.x ok" acima mede
  também a diferença de compilador.
- O ticket foi dividido em dois:
  - [#22440](https://bugs.ruby-lang.org/issues/22440): SEGV ao referenciar uma constante com
    *autoload* a partir de vários Ractors. O GCC 16 guarda o endereço TLS de `ruby_current_ec`; o
    escalonador M:N pode retomar a thread em outra thread nativa. PR
    [ruby/ruby#19348](https://github.com/ruby/ruby/pull/19348).
  - [#22442](https://bugs.ruby-lang.org/issues/22442): o carregamento preguiçoso do error_highlight
    era pulado em threads e Ractors. PR [ruby/ruby#19352](https://github.com/ruby/ruby/pull/19352).
- Teste com os dois patches sobre o master `3d168b1`, compilado com o GCC 16.2.1:

  | Script | sem patches (b709bdb3e3) | com os 2 patches |
  |---|---|---|
  | reprodutor do #22440 (8 Ractors) | 10/10 SEGV | 10/10 ok |
  | `repro.rb` (detailed_message, 2 Ractors) | 10/10 SEGV | 10/10 ok |
  | `repro_syntax_tree.rb` (2 Ractors) | 1/10 SEGV | 10/10 ok |
  | trecho do error_highlight nos 2 Ractors | não testável | 5/5 com trecho |

- Correção do relato original: a frase "Also seen on Ubuntu 24.04, AMD EPYC Genoa" estava errada;
  este reprodutor nunca rodou nessa máquina. A resposta enviada está em `REPLY_DRAFT.md`.

# frozen_string_literal: true

source "https://rubygems.org"

ruby ">= 4.0"

# Única dependência externa da POC: scheduler de Fibers (Fiber::Scheduler)
# para o modo `fibers`. Os modos sequential/threads/ractors não precisam dela.
gem "async", "~> 2.46"

# Vem com o Ruby, mas desde o 3.4 é "bundled gem": sob o Bundler precisa
# ser declarada (usada para gravar os CSVs de resultados).
gem "csv"

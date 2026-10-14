def msg_in_main
  nil.upcase
rescue => e
  e.detailed_message(highlight: false)
end
r = Ractor.new do
  begin
    nil.upcase
  rescue => e
    e.detailed_message(highlight: false)
  end
end
puts "--- principal:", msg_in_main, "--- dentro do Ractor:", r.value

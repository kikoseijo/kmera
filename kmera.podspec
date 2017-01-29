Pod::Spec.new do |s|
  s.name             = "kmera"
  s.version          = "1.0.0"
  s.summary          = "Swift class to access camera devices to record and shoot photos."
  s.requires_arc     = true
  s.homepage         = "https://github.com/kikoseijo/kmera"
  s.license          = 'MIT'
  s.author           = { "Kiko Seijo" => "kiko@sunnyface.com" }
  s.source           = { :git => "https://github.com/kikoseijo/kmera.git", :tag => "1.0.0" }
  s.social_media_url = 'http://www.sunnyface.com/'
  s.platform         = :ios, '8.0'
  s.source_files     = 'src/kmera.swift'
end

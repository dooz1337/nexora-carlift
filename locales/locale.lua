Locales = Locales or {}

function L(key, ...)
    local t = Locales[Config.Locale] or Locales.en
    local s = (t and t[key]) or (Locales.en and Locales.en[key]) or key
    if select('#', ...) > 0 then return s:format(...) end
    return s
end

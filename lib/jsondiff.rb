def recurse_sorted(result, indent = 0)
  case result
  when Array
    return "[\n" + " "*indent + result.map { |x| recurse_sorted x, indent + 2 }.join(",\n")+"\n"+" "*indent + "]"
  when Hash
    return "{\n" + " "*indent + result.sort.map { |x, y| recurse_sorted(x, indent + 2) + ": "+ recurse_sorted(y, indent + 2) }.join(",\n") + "\n"+" "*indent + "}"
  when String
    return " "*indent + "\"" + result + "\""
  else
    return " "*indent + result.to_s
  end
end


internet = require("internet")
filesystem = require("filesystem")
handle = internet.request("https://api.github.com/repos/Vedvart/Minecraft/contents")

result = ""

for chunk in handle do result = result..chunk end

while(not (string.find(result, "download_url") == nil)) do

  i, j = string.find(result, "download_url")
  qi, qj = string.find(string.sub(result, j+4,-1), '"')

  url = string.sub(result, j + 4, j + qi + 2)

  if string.sub(url, -14) == '.gitattributes' then goto continue end
  
  ni, nj = string.find(url, "Vedvart")
  filepath = string.sub(url, nj+2, -1)

  ri, rj = string.find(string.reverse(filepath), "/")
  if not filesystem.isDirectory("/home/github/"..string.sub(filepath, 1, -ri)) then
    filesystem.makeDirectory("/home/github/"..string.sub(filepath, 1, -ri))
  end

  file_content_handle = internet.request(url)
  file_content = ''
  for chunk in file_content_handle do file_content = file_content .. chunk end

  file = io.open('/home/github/'..filepath, 'w')
  file:write(file_content)
  file:close()

  print(file)

  ::continue::
  result = string.sub(result, j+qi+3, -1)

end

print('done')
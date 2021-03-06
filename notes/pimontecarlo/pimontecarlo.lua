
local st = 1234

local function rand ()
	-- 4005 = 2*2*7*11*13 + 1
	-- 165  = 3*5*11
	-- 0x10000 = 2**16 = 65536
	st = st * 4005 + 165
	while st >= 0x10000 do
		st = st - 0x10000
	end
	return st / 0x10000.0
end

local count = 2000
local i = 0
local inside = 0

local start = os.clock()

while i < count do
	local x = rand()
	local y = rand()
	if x*x + y*y <= 1.0 then
		inside = inside+1
	end
--	if i%250 == 0 then
--		io.write("\r" .. i .. ": " .. 4*inside/i)
--		io.write("               ")
--		io.flush()
--	end
	i = i+1
end

local fin = os.clock()
local time = fin - start

local pi = (inside / count)*4

print(count .. " samples, PI=" .. pi .. " in " .. time .. "s")

-- 2000 samples, PI=3.144 in 2.460937s


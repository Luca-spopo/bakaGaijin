--Please read the comments in bakaGaijinTest1 before or alongside these

--The syntax
--bakaGaijin["someString"] = someVar
--makes someVar usable by some other resource as
--bakaGaijin("nameOfThisResource")["someString"]

outputChatBox("bakaGaijinTest2 loaded")

function start(bg)

	if getResourceName( bg ) ~= "bakaGaijin" then
		return
	end

	loadstring(exports["bakaGaijin"]:use())()

	bakaGaijin.reset = function()
		--Resets the state of the resource to ready it for another test
		--This function can be called by other resources.
		globalTable1 = nil
		bakaGaijin.MyT1 = nil
		bakaUpdateATC(true)
	end

	bakaGaijin["step1"] = function()
		globalTable1 = bakaGaijin("bakaGaijinTest1").table1
		--the table is {1, 2, 3, x=4}

		-- '#' operator DOES NOT WORK for foreign objects
		-- This will be fixed if MTA ever upgrades to Lua 5.2
		-- Use len() function instead.

		assert(len(globalTable1) == 3)

		for i, v in ipairs( globalTable1 ) do
			--iterators work properly even on foreign objects
			globalTable1[i] = v+1
		end
		for i, v in pairs( globalTable1 ) do
			globalTable1[i] = v+1
			if type(i) == "table" then
				assert(i[1] == "abc") --One of the indices is a table. Stuff like this works.
			end
		end
	end

	--This syntax also works, and is the cutest
	function bakaGaijin.step2 ()
		assert(bakaGaijin("bakaGaijinTest1").table1 == nil)
		--The other resource has stopped exposing it's t1 as table1
		--Don't worry, we can still use it using globalTable1
	end

	function bakaGaijin.step3 ()
		--At this point the other resource has done
		-- `t1[t1] = t1`
		--So the table is recursive

		return globalTable1[globalTable1][globalTable1][3]
		--Returning values is not a problem

	end

	function bakaGaijin.step4(someFunction)
		--The other resouce wants us to do t1[f1](t1, "arg2")
		local a, b, c = globalTable1[someFunction](globalTable1, "arg2")
		--should return t1, f1
		--Best way to check equality is using the objects as keys.
		local keyTest = {[a] = false, [b] = false}
		keyTest[globalTable1] = true
		keyTest[someFunction] = true
		assert(keyTest[a])
		assert(keyTest[b])
		assert(c == nil)

		--Lets check their types
		assert(type(a) == "table")
		assert(type(b) == "function")

	end

	--Note that functions don't have to be global to be exported
	local function temp_step5()
		--The other resouce wants us expose globalTable1 as MyT1
		bakaGaijin.MyT1 = globalTable1
	end
	bakaGaijin.step5 = temp_step5

	function bakaGaijin.step6(table)
		--table should be {{{42}}}
		assert(table[1][1][1] == 42)
	end

	function bakaGaijin.step7()
		--globalTable1 has it's metatable set up to let us call it
		globalTable1(1, globalTable1)
		outputDebugString("Ignore any warning message above. We are testing __call metamethod.", 0, 100, 100, 200)
	end

	function bakaGaijin.step8()
		--globalTable1 has metamethods set up for index and newindex
		assert(globalTable1.inheritedVariable)
		globalTable1.nonExistantVariable = 42
	end

	function bakaGaijin.step9()
		--globalTable1 has an index metamethod as a function that returns true
		assert(globalTable1.nonExistantVariable)
	end

	function bakaGaijin.getObj()
		return {} --returns a freshly created new object
	end

	--Runs the Lua GC, checks if any gaijins are unused, and informs their host resources.
	--Then displays the gaijin usage by this resource in console
	addCommandHandler( "clean1", 
	function()
		outputConsole( "running bakaUpdateATC for bakaGaijinTest1")
		bakaUpdateATC(true)
		--bakaUpdateATC is a global function provided by bakaGaijin
		--This checks if any variables imported from other resources are still in memory
		--If they are not in memory, the host resource is informed.
		--If the host resource realizes that no resource is using it's exported variable,
		--it stops exporting it.
		--It has an optional parameter. If this parameter evaluates to true, then the Lua
		--garbage collector is run before the actual checking, to do an accurate job.
		--As such, this function is called at a fixed time interval anyway.
		--garbage collection is done explicitely every 10 calls (including the timed ones)
		--This number can be changed in bakaGaijin.lua
		--This function is also automatically called if another resource feels that this resource
		--is importing too many objects from it.
		--The threshold for when a resource feels such emotions increases dynamically based
		--on this resource's usage.
		showBaka()
	end
	 )

	--Shows the gaijin usage by this resource in console
	--Giving a parameter in the command will show detailed usage
	addCommandHandler( "count1", 
	function(cmd, verbose)
		showBaka(verbose)
		--showBaka is a global function provided by bakaGaijin.
		--The first optional parameter is a boolean specifying if detailed usage should be given.
		--The second optional parameter is a function that will be called to display the output
		--Default value of second parameter is "outputConsole"
		--It implicitly uses getBaka to get the information to display
	end
	 )
end

addCommandHandler( "bakaTest",
function()
	local bgt1 = getResourceFromName( "bakaGaijinTest1" )
	bgt1 = bgt1 and getResourceState( bgt1 ) == "running"

	if not bgt1 then
		outputChatBox("Start bakaGaijinTest1 first!")
		return
	end
end
)

local bg = getResourceFromName( "bakaGaijin" )
if bg and getResourceState( bg ) == "running" then
	start(bg)
else 
	addEventHandler( "onClientResourceStart", getRootElement(), start)
end
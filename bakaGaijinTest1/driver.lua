outputChatBox("bakaGaijinTest1 loaded")

local function reset()
	--Resets the state of the resource to ready it for another test
	bakaGaijin.table1 = nil
	bakaUpdateATC(true)
end

local function startTest()
	local bgt2 = getResourceFromName( "bakaGaijinTest2" )
	bgt2 = bgt2 and getResourceState( bgt2 ) == "running"

	local bg = getResourceFromName( "bakaGaijin" )
	bg = bg and getResourceState( bg ) == "running"

	if not bg then
		outputChatBox("Start bakaGaijin first!")
		return
	elseif not bgt2 then
		outputChatBox("Start bakaGaijinTest2 first!")
		return
	end

	loadstring(exports["bakaGaijin"]:use())()

	bakaGaijin("bakaGaijinTest2").reset()
	--Tells bakaGaijinTest2 to reset it's state in case tests were run before.
	reset();
	--Resets own state in case tests were run before

	outputChatBox("Running the tests!")
	outputDebugString("Running the tests!", 0, 100, 100, 200)

	local startTime = getTickCount(  )

	local bakaGaijinTest2 = bakaGaijin("bakaGaijinTest2")
	--To access a registered variable in bakaGaijinTest2, now we can do bakaGaijinTest2.variable

	local tempindex = {"abc"}
	local t1 = {1, 2, 3, x=4, [tempindex] = 5}
	bakaGaijin.table1 = t1
	--Other resources can now access t1 as bakaGaijin("bakaGaijinTest1").table1

	bakaGaijinTest2.step1()
	--Tells the other resource to access t1 and increment it's values
	--Once using ipairs, and once using pairs. So ones in ipairs will be incremented twice.

	assert(type(bakaGaijinTest2.step1) == "function")
	--Type checking works
	assert(t1[1] == 3)
	assert(t1[2] == 4)
	assert(t1[3] == 5)
	assert(t1.x == 5)
	assert(t1[tempindex] == 6)

	--default pairs and ipairs have been overridden, but I've been careful
	--to keep them super fast.
	local kek = {1, 2, x=3, y=4, [tempindex]=5}
	for i, v in pairs(kek) do
		if i == tempindex then
			assert(v==5)
		end
	end
	for i, v in ipairs(kek) do
		if i==2 then
			assert(v==2)
		end
		if v == 5 then
			assert(false) --v should never be 5
		end
	end

	bakaGaijin["table1"] = nil
	--Syntactically equal to `bakaGaijin.table1 = nil`
	--Other resources can no longer access t1 as bakaGaijin("bakaGaijinTest1").table1
	--However, they can still use it if they saved it in a variable while it was still accessible.
	--You can see how cute the syntax is. Just do bakaGaijin.someString = someVar to export someVar

	--As you can see, you can export a variable at runtime.

	bakaGaijinTest2.step2({10, 20, 30})
	--Verify that bakaGaijin("bakaGaijinTest1").table1 returns nil for other resource
	--(The other resource can still use it though, since we saved it in a variable there,
	--as you will see in the other file)
	--The other function does not expect any parameters. The parameters provided will be
	--discarded as Lua normally does.

	t1[t1] = t1
	--Indices can be objects
	--Self reference is not a problem, everything is lazy evaluated

	local num = bakaGaijinTest2.step3()
	--Asks other resource to try accessing t1[3] as t1[t1][t1][3] and return it's value

	assert(num == 5)

	local f1_was_called = false

	local function f1 (A, B, C)
		--This function expects t1 as parameter A
		--(This function will be called by the other resource)

		f1_was_called = true
		--Marks the flag so we can check if this code ever ran

		assert(A == t1)

		local temp = {}
		temp[A] = false
		temp[t1] = true
		assert(temp[A])
		--Index identity is also preserved.

		assert(B == "arg2")
		--multiple parameters is not a problem

		assert(C == nil)
		--This function was called with just 2 parameters

		return t1, f1
		--Returning multiple variables is not a problem
		--Returning a function is not a problem

		--returning a set of values with a nil in between is a problem
		--`return t1, nil, f1` will not work
		--This will be fixed in future versions
	end

	t1[f1] = f1
	--functions also work naturally

	bakaGaijinTest2.step4(f1)
	--Asks the other resource to run f1 using t1[f1](t1, "arg2")
	--Which would be the same as doing f1(t1, "arg2")
	--Also asks it to assert that the returned values are t1, f1
	
	assert(f1_was_called)
	--Checks that the function was actually called

	assert(bakaGaijinTest2.MyT1 == nil)
	--The other resource is not exposing any such variable at this time

	bakaGaijinTest2.step5()
	--Asks the other resource to expose it's version of t1 as a variable called "MyT1"

	assert(bakaGaijinTest2.MyT1 == t1)
	--It is exposing it now, and it is the same table.

	bakaGaijinTest2.step6( { { {42} } } )
	--Nested tables are obviously not a problem.
	--Asks the other function to make sure that PARAMETER[1][1][1] is 42

	local meta = {__call = function(self, num, t)
		self.I_was_called = true
		assert(num==1)
		assert(t==self)
	end}
	setmetatable(t1, meta)

	bakaGaijinTest2.step7()
	--Asks the other resource to try calling t1(1, t1)
	--Metatables are not lost, and still work.

	assert(t1.I_was_called)

	meta.__index = {inheritedVariable = true}

	local newindex_was_called = false --flag variable

	meta.__newindex = function(t)
		assert(t == t1)
		newindex_was_called = true
	end

	bakaGaijinTest2.step8()
	--Asks the other resource to assert that t1.inheritedVariable is true
	--Asks the other resouce to set value for t1.nonExistantVariable to some value

	assert(newindex_was_called)

	meta.__index = function() return true end

	bakaGaijinTest2.step9()
	--Asks the other resource to assert that t1.nonExistantVariable is true

	--Now we will test the bakaGaijin garbage collector
	--Every time bakaGaijinTest2.getObj is called, an object is returned. This resource is requesting
	--a "lock" on that object when this happens, so the other resource doesnt delete it.
	--After >100 locks on objects, the other resource will request this one to free some resources.
	--This will unlock any locks that this resource is not using.
	--If this resource is not able to reduce the number of locks to a number below 72, then the
	--allowance of this resource is increased. The other resource will let this one lock 40% more objects
	--than it is already locking after it has unlocked everything it can.
	--If it exceeds this limit, the cleanup is run again, and the allowance revised if needed.


	local getForeignObject = bakaGaijinTest2.getObj
	local gc_took_place = false
	local last_count = 0
	--The while loop below will ensure one garbage collection cycle.
	while true do
		local a = getForeignObject()
		local _, __, ___, usage = getBaka()
		--getBaka is a function provided by bakaGaijin that returns:
		---the number of functions/tables being exported by this resource
		---the number of functions/tables being locked by this resource
		---table of details (per resource) of functions/tables being exported by this resource
		---table of details (per resource) of functions/tables being locked by this resource
		--We will only use the last value

		local count = usage["bakaGaijinTest2"] --Number of objects locked on the other resource.
		assert(count)
		if count > 100 then --ASSUMING LOAD_MIN WAS SET TO 100
			--GC should have taken place, but it didnt
			break
		elseif count >= last_count then
			last_count = count
		else
			gc_took_place = true

			break
		end
	end
	assert(gc_took_place)
	--Since all the locks were elligible for GC, we are back to square 1, as if those objects were
	--never locked.

	local these_objects_cant_be_GCed = {}
	last_count = 0
	gc_took_place = false
	--This while loop will ensure one GC cycle when 100 objects get locked
	--But they will not be elligible for GC, so instead the allowance of this resource
	--should get increased
	while true do
		local a = getForeignObject()
		table.insert(these_objects_cant_be_GCed, a)
		local _, __, ___, usage = getBaka()
		local count = usage["bakaGaijinTest2"] --Number of objects locked on the other resource.
		assert(count)
		if count > 100 then
			--GC took place, but couldn't free many objects
			--So instead, the number of objects allowed have been set to a higher number.
			gc_took_place = true
			
			break
		elseif count >= last_count then
			last_count = count
		else
			--GC took place, and it removed some objects
			gc_took_place = true
			assert(false) --It should not be able to remove any objects though
		end
	end
	assert(gc_took_place)

	for i in ipairs(these_objects_cant_be_GCed) do
		these_objects_cant_be_GCed[i] = nil
	end

	--Now, this resource should be able to lock 140 objects without being asked any questions.
	--However, once it reaches 140, the GC will happen again.
	--It will find out that the previous locks are no longer usable, and will deallocate them
	--and the lock limit will be reset to 100

	last_count = 0
	gc_took_place = false
	--The while loop below will ensure one garbage collection cycle.
	while true do
		local a = getForeignObject()
		local _, __, ___, usage = getBaka()
		local count = usage["bakaGaijinTest2"] --Number of objects locked on the other resource.
		assert(count)
		if count > 140 then --ASSUMING LOAD_GAIN_TOLERANCE is 1.4
			--GC should have taken place, but it didnt
			break
		elseif count >= last_count then
			last_count = count
		else
			assert(last_count > 101) --It had gone beyond the previous limit before being GCed
			
			gc_took_place = true
			break
		end
	end
	assert(gc_took_place)

	--At this point the lock limit should be 100 again.
	
	last_count = 0
	gc_took_place = false
	while true do
		local a = getForeignObject()
		local _, __, ___, usage = getBaka()
		local count = usage["bakaGaijinTest2"] --Number of objects locked on the other resource.
		assert(count)
		if count > 100 then --ASSUMING LOAD_MIN WAS SET TO 100
			--GC should have taken place, but it didnt
			break
		elseif count >= last_count then
			last_count = count
		else
			gc_took_place = true
			
			break
		end
	end
	assert(gc_took_place)
	
	local endTime = getTickCount(  )

	outputChatBox( "All tests completed in "..endTime-startTime.." ticks."  )

end

addCommandHandler( "bakaTest", startTest)

--Runs the Lua GC, checks if any gaijins are unused, and informs their host resources.
--Then displays the gaijin usage by this resource in console
addCommandHandler( "clean1", 
function()
	outputConsole( "running bakaUpdateATC for bakaGaijinTest1")
	bakaUpdateATC(true)
	showBaka()
end
 )

--Shows the gaijin usage by this resource in console
--Giving a parameter in the command will show detailed usage
addCommandHandler( "count1", 
function(cmd, verbose)
	showBaka(verbose)
end
 )
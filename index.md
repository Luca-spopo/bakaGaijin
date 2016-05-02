bakaGaijin
==========
Script for Multi Theft Auto to allow seamless cross-resource communication across Lua virtual machines.

Overview
--------
bakaGaijin is a script that provides an interface for your resources to communicate with each other.
Whereas traditional cross-resource communication results in tables being passed by value, and loss of certain information that cannot be serialized (functions and metamethods), bakaGaijin keeps the original object stored in the host resource itself, and sends a proxy object that can be used by other resources to request the host resource to perform operations on the original object.
This means that functions can be passed from one resource to another, tables can be passed by value and metatable operations still work, among other things.
The catch is, that the host resource must be running for another resource to use a function or table it received from the host resource.

bakaGaijin consists of:  
- bakaGaijin.lua, a script file that let's a resource use bakaGaijin to communicate with other resources using the same version of bakaGaijin.
- bakaGaijin resource, an optional resource that exports the function "use" which returns a string consisting of all the code in bakaGaijin.lua. You can use this with loadstring to load the library without including the script file. Useful to keep all your resources running the same version of bakaGaijin without manually changing their files.
- bakaGaijinTest1 and bakaGaijinTest2, resources that test and highlight all the features provided by bakaGaijin.

How to use it
-------------
You can find examples [here](howto.html).

How it works
------------
You can find documentation about how it works [here](magic.html).
Further detailed documentation is in the [source code](https://github.com/Luca-spopo/bakaGaijin/blob/master/bakaGaijin/bakaGaijin.lua) itself.

Download
--------
You can fork bakaGaijin or browse its source code on it's [GitHub repository](https://github.com/Luca-spopo/bakaGaijin).
Or you can [download](https://github.com/Luca-spopo/bakaGaijin/archive/master.zip) the repo as a zip file. 
This will download the main resource and two example test resources.
If you wish to use bakaGaijin.lua directly, it is located in the bakaGaijin folder in the same zip file.

Credits
------
bakaGaijin was made by Anirudh Katoch &copy; and released under the MIT open source license.
You can contact me at katoch.anirudh(at)gmail(dot)com
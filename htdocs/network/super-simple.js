



function setupchart(){
console.log("ready");
$.getJSON("https://meterlogger.net/network_data", {},
function (flat) {

var flatNodes = [
{
id:"root",
name:"root",
parent:0}];

var makeTree = (function() {
    var defaultClone = function(record) {
        var newRecord = JSON.parse(JSON.stringify(record));

        delete newRecord.parent;	

        return {
HTMLclass:newRecord.HTMLclass, 

innerHTML:'<div class="node-title">'+newRecord.name+'</div>'+
'<div class="node-ssid"><b>ssid: </b> '+newRecord.id+'</div>'+
'<div class="node-rssi"><b>rssi: </b>'+newRecord.rssi+'</div>'+
'<div class="node-version"><b>version: </b>'+newRecord.version+'</div>'};
    };
    return function(flat, clone) {
        return flat.reduce(function(data, record) {
            var oldRecord = data.catalog[record.id];
            var newRecord = (clone || defaultClone)(record);
            if (oldRecord && oldRecord.children) {
                newRecord.children = oldRecord.children;
            }
            data.catalog[record.id] = newRecord;
            if (record.parent) {
                var parent = data.catalog[record.parent] = 
                        (data.catalog[record.parent] || {id: record.parent});
                (parent.children = parent.children || []).push(newRecord);
            } else {
                data.tree.push(newRecord);
            }
            return data;
        }, {catalog: {}, tree: []}).tree;
    }
}());
var usedRouters = {};
var now = Date.now()/1000.0;
for (var i = 0; i < flat.length-1; i++) {
	var lastTime = flat[i][5];
	var timeSinceLast = now - lastTime;
    var n = {
        id: flat[i][3],
        name: flat[i][1],
        parent: flat[i][2],
		rssi: flat[i][4] + "db",
		version: flat[i][6],
HTMLclass: 'green'
    };




	if ( timeSinceLast > 86400){
n.HTMLclass = 'red';
	} else if (timeSinceLast > 3600){
n.HTMLclass = 'yellow';
} 

	if (n.parent != ""){
	flatNodes.push(n)
}
else {
    console.log(JSON.stringify(n));
    }
	if (!n.parent.startsWith("mesh") && !usedRouters[n.parent]){
		var parent = {
id:n.parent,
name: "router",
parent: "root",
desc:"",
HTMLclass: 'green'
}
usedRouters[n.parent] = parent;
flatNodes.push(parent);
}
}

var tree = makeTree(flatNodes)

var simple_chart_config = {
	chart: {
		container: "#OrganiseChart-simple",
hideRootNode: true,
rootOrientation: 'WEST',
     node: {
            HTMLclass: 'nodeExample1'
}
	},
	
	nodeStructure:tree[0]
};

new Treant( simple_chart_config );
    // Your `success` code
}).fail(function (jqXHR, textStatus, errorThrown) {
    alert("AJAX call failed: " + textStatus + ", " + errorThrown + JSON.stringify(jqXHR));
});


};



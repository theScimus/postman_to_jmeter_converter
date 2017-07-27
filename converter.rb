#!/bin/ruby
require 'json'
require 'nokogiri'
require 'uri'

# Parse args
postman_file = nil
postman_env_file = nil
jmeter_file = nil
out_file = nil

ARGV.each do|a|
	arg = a.split('=')
	if arg[0] == '--postman_file'
		postman_file = arg[1].strip
  		puts "Postman tests file: #{arg[1]}"
  	end

  	if arg[0] == '--postman_env_file'
		postman_env_file = arg[1].strip
  		puts "Postman environment file: #{arg[1]}"
  	end

  	if arg[0] == '--out_file'
  		out_file = arg[1].strip
  		puts "Postman ouput file: #{arg[1]}"
  	end
end

if postman_file.nil?
	p "--postman_file is not set"
	exit
end

if postman_env_file.nil?
	p "--postman_env_file is not set"
	exit
end

begin
	postman_file = File.read(postman_file)
rescue
	p "File #{postman_file} is not found. Make sure you set a correct path"
end

begin
	postman_env_file = File.read(postman_env_file)
rescue
	p "File #{postman_env_file} is not found. Make sure you set a correct path"
end

test_hash = nil
env_hash = nil

begin
	test_hash = JSON.parse(postman_file)
rescue
	p "Cannot parse #{postman_file} as json file"
end

begin
	env_hash = JSON.parse(postman_env_file)
rescue
	p "Cannot parse #{postman_file} as json file"
end

def collect_vars arr
	result = []
	arr.select{|el| el.match(/postman.setEnvironmentVariable/)}.each do |var|
		set = var.split("(")[1].split(",")
		page_values = set[1].gsub(/\);/,'').split('[').select{|e| !e.gsub!("]","").nil?}.map{|d| d.gsub("'","")}
		result.push({:var_name=>JSON.parse(set[0]), :page_value=>{:element => page_values.last, :index => page_values[-1].match(/d+/) ? page_values[-1] : 0}})
	end
	result.empty? ? nil : result
end

def generate_json_with_var postman_file, postman_env_file
	begin
		env_hash = JSON.parse(postman_env_file)
	rescue
		p "Cannot parse #{postman_file} as json file"
	end

	variables = {}
	env_hash["values"].collect{|element| variables[element["key"]] = element["value"] }
	variables.each do |key, value|
		postman_file.gsub!(/\{\{#{key}\}\}/, value)
	end

	begin
		test_hash = JSON.parse(postman_file)
	rescue
		p "Cannot parse #{postman_file} as json file"
	end
	test_hash
end

def collect_requests input
	res = []
	input['item'].each do |i|
		i["item"].each do |test|
			vars = collect_vars test["event"].first["script"]["exec"] if test["event"]
			test["request"]["vars"] = vars if !vars.nil?
			res.push(test["request"])
		end
	end
	res
end

test_hash = generate_json_with_var postman_file, postman_env_file
requests = collect_requests test_hash

builder = Nokogiri::XML::Builder.new do |xml|
  xml.jmeterTestPlan("version"=>"1.2", "properties"=>"2.8", "jmeter"=>"2.13 r1665067") {
    xml.hashTree {
      xml.TestPlan("guiclass"=>"TestPlanGui", "testclass"=>"TestPlan", "testname"=>"Stress Tests", "enabled"=>"true") {
      	xml.boolProp(false, "name"=>"TestPlan.functional_mode")
      	xml.boolProp(false, "name"=>"TestPlan.serialize_threadgroups")
      	xml.elementProp("name"=>"TestPlan.user_defined_variables", "elementType"=>"Arguments", "guiclass"=>"ArgumentsPanel", "testclass"=>"Arguments", "testname"=>"User Defined Variables", "enabled"=>"true"){
      		xml.collectionProp("name"=>"Arguments.arguments")
      	}
      	xml.stringProp("name"=>"TestPlan.user_define_classpath")
      }
      xml.hashTree {
      	xml.ThreadGroup("guiclass"=>"ThreadGroupGui", "testclass"=>"ThreadGroup", "testname"=>"Juvly API Performance Test", "enabled"=>"true"){
      		xml.stringProp("continue", "name"=>"TestPlan.serialize_threadgroups")
      		xml.elementProp("name"=>"ThreadGroup.main_controller", "elementType"=>"LoopController", "guiclass"=>"LoopControlPanel", "testclass"=>"LoopController", "testname"=>"Loop Controller", "enabled"=>"true") {
      			xml.boolProp(false, "name"=>"LoopController.continue_forever")
      			xml.stringProp(1, "name"=>"LoopController.loops")
      		}
      		xml.stringProp(1, "name"=>"ThreadGroup.num_threads")
      		xml.stringProp(1, "name"=>"ThreadGroup.ramp_time")
      		xml.boolProp(false, "name"=>"ThreadGroup.scheduler")
      		xml.stringProp("name"=>"ThreadGroup.duration")
      		xml.stringProp("name"=>"ThreadGroup.delay")
      	}
      		xml.hashTree {
      			requests.each do |request|
      			vars = request['url'].split('/').select{|p| p.match(/{{.+}}/)}.map{|v| v.gsub(/{{|}}/,'')}
      			vars.each do |v|
      				request['url'].gsub!(/{{|}}/, '')
      			end
      			uri = URI(request['url'])
      			vars.each do |v|
      				uri.path.gsub!(/#{v}/, "${#{v}}")
      			end
		      		xml.HTTPSamplerProxy("guiclass"=>"HttpTestSampleGui", "testclass"=>"HTTPSamplerProxy", "testname"=>"#{request['url']}", "enabled"=>"true"){
		      			xml.elementProp("name"=>"HTTPsampler.Arguments", "elementType"=>"Arguments", "guiclass"=>"HTTPArgumentsPanel", "testclass"=>"Arguments", "enabled"=>"true"){
		      				if(!request['body'].empty?)
			      				xml.collectionProp("name"=>"Arguments.arguments"){
			      					request['body']['formdata'].each do |formelement|
				      						xml.elementProp("name"=>"#{formelement['key']}", "elementType"=>"HTTPArgument"){
				      						xml.boolProp(false, "name"=>"HTTPArgument.always_encode")
				      						xml.stringProp(formelement['key'], "name"=>"Argument.name")
				      						xml.stringProp(formelement['value'], "name"=>"Argument.value")
				      						xml.stringProp("=", "name"=>"Argument.metadata")
				      						xml.boolProp(true, "name"=>"HTTPArgument.use_equals")
			      						}
			      					end
			      				}
			      			end
			      		}	
		      			xml.stringProp("#{uri.host}", "name"=>"HTTPSampler.domain")
		      			xml.stringProp("#{uri.port}", "name"=>"HTTPSampler.port")
		      			xml.stringProp("name"=>"HTTPSampler.connect_timeout")
		      			xml.stringProp("name"=>"HTTPSampler.response_timeout")
		      			xml.stringProp("#{uri.scheme}", "name"=>"HTTPSampler.protocol")
		      			xml.stringProp("name"=>"HTTPSampler.contentEncoding")
		      			xml.stringProp("#{uri.path}", "name"=>"HTTPSampler.path")
		      			xml.stringProp("#{request['method']}","name"=>"HTTPSampler.method")
		      			xml.boolProp(true,"name"=>"HTTPSampler.follow_redirects")
		      			xml.boolProp(false,"name"=>"HTTPSampler.auto_redirects")
		      			xml.boolProp(true,"name"=>"HTTPSampler.use_keepalive")
		          		xml.boolProp(true,"name"=>"HTTPSampler.DO_MULTIPART_POST")
		          		xml.boolProp(true,"name"=>"HTTPSampler.BROWSER_COMPATIBLE_MULTIPART")
		          		xml.boolProp(false,"name"=>"HTTPSampler.monitor")
		          		xml.stringProp("name"=>"HTTPSampler.embedded_url_re")
		      		}
		      		xml.hashTree{
		      			xml.HeaderManager("guiclass"=>"HeaderPanel", "testclass"=>"HeaderManager", "testname"=>"HTTP Header Manager", "enabled"=>"true"){
			      			xml.collectionProp("name"=>"HeaderManager.headers"){
			      				request['header'].each do |header|
			      					xml.elementProp("name"=>"#{header['key']}", "elementType"=>"Header"){
			      						xml.stringProp("#{header['key']}","name"=>"Header.name")
			      						xml.stringProp("#{header['value']}","name"=>"Header.value")
			      					}	
			      				end
			      			}
		      			}
		      			if !request["vars"].nil?
		      				xml.hashTree
		      				request["vars"].each do |var|
				      			
				      			xml.RegexExtractor("guiclass"=>"RegexExtractorGui", "testclass"=>"RegexExtractor", "testname"=>"Regular Expression Extractor", "enabled"=>"true"){
				      				xml.stringProp(false,"name"=>"RegexExtractor.useHeaders")
				      				xml.stringProp(var[:var_name],"name"=>"RegexExtractor.refname")
				      				xml.stringProp("\"#{var[:page_value][:element]}\":\"(.+?)\"","name"=>"RegexExtractor.regex")
				      				xml.stringProp("$1$","name"=>"RegexExtractor.template")
				      				xml.stringProp(0,"name"=>"RegexExtractor.default")
				      				xml.stringProp(1,"name"=>"RegexExtractor.match_number")
				      			}
				      			xml.hashTree
				      		end
				      		
			      		end
		      		}
	      		end
      		}  	
      	}
    }
  }
end
outFile = File.new(out_file, "w+")
outFile.puts builder.to_xml
outFile.close
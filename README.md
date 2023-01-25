# Logstash CI testing harness

This is a little tool to be able to run CI tests on Logstash configuration.

## Requirements
The tool calls out to `docker` on the host platform to spin up a Logstash container to test. It also calls out to `diff` when tests fail.
It is written in Ruby, but should run without extra gems needing to be installed on a standard ruby installation.
During the run, it allocates port 9600 and random ports above 3200 for each pipeline it tests. If those are not available, the test will fail.

## Logstash Configuration peculiarities
It has some restrictions, as doing a full parser of the Logstash configuration format was... painful, so
you will have to mark up your inputs and outputs in your Logstash pipelines as follows:

```
input {
###INPUT###
  beats {
    id => "beats"
    port => 5044
  }
###END###
}
```

and 

```
output {
###OUTPUT###
  stdout {
    id => "stdout"
    codec => rubydebug
  }
###END###
}
```

The id attribute on the inputs and outputs are mandatory (to be able to identify them when writing tests (and good practice either way)).

## Writing tests
The tests are very simplistic. Place files in a directory. Each containing an INPUT block followed with how the log input will look (if delivered as JSON lines), and followed immediately by a OUTPUT block for the various outputs you expect to have output (again, in JSON format).

For example:
```
###INPUT-beats###
{
  "action": "login",
  "secret": "VerySecretPassword"
}
###OUTPUT-stdout###
{
  "action": "login"
}
```
where an input is expected on the `beats` input, and a filtered output is expected on the `stdout` output.
If you want to test for the absence of output, don't include the OUTPUT block and the test will time out after a few seconds to confirm there was no output.

## Examples
Included in the `examples` directory is a simplistic Logstash configuration and a test file with two tests that will succeed, and one that will fail.
You can run it with `ruby test.rb -c example/config/ -t example/tests/ -p example/pipelines/` which should give you the following output:

![example](https://github.com/mgust/logstash-ci/blob/master/.github/example.png?raw=true)

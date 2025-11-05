// Local Ollama client configuration
// Make sure Ollama is running with: ollama serve
// Pull the model with: ollama pull qwen3:1.7b
client<llm> LocalQwen3 {
  provider "openai-generic"
  options {
    base_url "http://localhost:11434/v1"
    model "qwen3:1.7b"
  }
}

// Cloud provider clients (commented out - using local model)
// client GPT4 {
//     provider openai
//     options {
//         model gpt-4o-mini
//         api_key env.OPENAI_API_KEY
//     }
// }

// client DeepSeekR1 {
//   provider openai-generic
//   options {
//     base_url "https://api.together.ai/v1"
//     api_key env.TOGETHER_API_KEY
//     model "deepseek-ai/DeepSeek-R1-Distill-Llama-70B-free"
//   }
// }

// client Claude35Sonnet {
//     provider anthropic
//     options {
//         model claude-3-5-sonnet-latest
//         api_key env.ANTHROPIC_API_KEY
//     }
// }

// client Gemini25Pro {
//   provider google-ai
//   options {
//     model "gemini-2.5-pro"
//     api_key env.GEMINI_API_KEY
//   }
// }

function ExtractPerson(info: string) -> Person {
    client LocalQwen3
    prompt #"
        {{ ctx.output_format }}

        Extract the person's information from the following string:
        {{ info }}
    "#
}

class Person {
    name string
    age int
}

function DescribeImage(myImg: image) -> string {
  client LocalQwen3
  prompt #"
    {{ _.role("user")}}
    Describe the image in four words:
    {{ myImg }}
  "#
}

enum Model {
  DeepSeekR1
  GPT4oMini
}

class MyClass {
  property1 string
  property2 int?
  @@dynamic // allows adding fields dynamically at runtime
}

class NewEmployeeFullyDynamic {
  employee_id string
  @@dynamic // allows adding fields dynamically at runtime
}

function CreateEmployee() -> NewEmployeeFullyDynamic {
  client LocalQwen3
  prompt #"
    Create a fake employee data with the following information:
    {{ ctx.output_format }}
  "#
}

function WhichModel() -> Model {
    client LocalQwen3
    prompt #"
        Which model are you?

        {{ ctx.output_format }}
    "#
}

function WhichModelUnion() -> "DeepSeek" | "GPT" {
  client LocalQwen3
  prompt #"
    Which model are you?

    {{ ctx.output_format }}
  "#
}

class DummyOutput {
  nonce string
  nonce2 string
}

function DummyOutputFunction() -> DummyOutput {
  client LocalQwen3
  prompt #"
    Say "hello there".
  "#
}

class Attendees {
  hosts Person[]
  guests Person[]
}

function ParseAttendees(attendees: string) -> Attendees {
  client LocalQwen3
  prompt #"
    {{ ctx.output_format }}

    Parse the following string into an Attendees struct:
    {{ attendees }}
  "#
}

function FlipSwitch(switch: bool) -> bool {
  client LocalQwen3
  prompt #"
    Flip the switch:
    {{ switch }}

    {{ ctx.output_format }}
  "#
}
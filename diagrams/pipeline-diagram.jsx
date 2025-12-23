import React, { useState } from 'react';

const PipelineDiagram = () => {
  const [selectedComponent, setSelectedComponent] = useState(null);
  const [activeTab, setActiveTab] = useState('architecture');

  const components = {
    s3Input: {
      name: 'S3 Input Bucket',
      type: 'storage',
      icon: '📦',
      color: '#ff9f43',
      details: {
        purpose: 'Receives incoming NDJSON files from data sources',
        specs: ['3.5MB files', '~200K files/hour', 'Date-prefixed naming'],
        config: ['SSE-S3 encryption', 'Versioning enabled', 'Event notifications to SQS']
      }
    },
    sqs: {
      name: 'SQS Queue',
      type: 'queue',
      icon: '📮',
      color: '#00d4ff',
      details: {
        purpose: 'Decouples file ingestion from processing for reliability',
        specs: ['55 messages/second', '15 min visibility timeout', '14-day retention'],
        config: ['Dead Letter Queue', 'Long polling (20s)', 'Max receive count: 3']
      }
    },
    lambda1: {
      name: 'Manifest Builder',
      type: 'compute',
      icon: 'λ',
      color: '#ff6b6b',
      details: {
        purpose: 'Validates files and creates 1GB batch manifests',
        specs: ['512MB memory', '3 min timeout', 'Batch size: 10 messages'],
        config: ['Distributed locking', 'DynamoDB tracking', 'Configurable validation']
      }
    },
    glue: {
      name: 'Glue Streaming',
      type: 'compute',
      icon: '🔧',
      color: '#a55eea',
      details: {
        purpose: '24/7 streaming conversion of NDJSON to Parquet',
        specs: ['10 × G.2X workers', '2-5 min per batch', 'Snappy compression'],
        config: ['Checkpointing', 'Adaptive query execution', '128MB target files']
      }
    },
    dynamodb: {
      name: 'DynamoDB',
      type: 'database',
      icon: '🗄️',
      color: '#26de81',
      details: {
        purpose: 'Tracks file status and stores pipeline metrics',
        specs: ['On-demand billing', '7-day TTL', 'GSI for status queries'],
        config: ['Point-in-time recovery', 'Stream enabled', 'Distributed locking support']
      }
    },
    s3Output: {
      name: 'S3 Output Bucket',
      type: 'storage',
      icon: '📦',
      color: '#ff9f43',
      details: {
        purpose: 'Stores converted Parquet files with date partitioning',
        specs: ['~700GB/hour', 'Parquet format', '128MB target files'],
        config: ['Intelligent Tiering', 'Versioning enabled', 'Deletion protection']
      }
    },
    controlPlane: {
      name: 'Control Plane',
      type: 'compute',
      icon: '🎮',
      color: '#ff6b6b',
      details: {
        purpose: 'Manages job state, metrics, and alerting',
        specs: ['256MB memory', '1 min timeout', 'EventBridge triggered'],
        config: ['Anomaly detection', 'Cost tracking', 'SNS integration']
      }
    },
    cloudwatch: {
      name: 'CloudWatch',
      type: 'monitoring',
      icon: '📈',
      color: '#74b9ff',
      details: {
        purpose: 'Centralized monitoring, metrics, and alerting',
        specs: ['Custom namespace', 'Dashboard', 'Multiple alarms'],
        config: ['DLQ alarm', 'Error alarm', 'Job failure alarm', 'Queue backlog alarm']
      }
    }
  };

  const dataFlow = [
    { from: 'Data Source', to: 'S3 Input', label: 'Upload NDJSON', type: 'data' },
    { from: 'S3 Input', to: 'SQS', label: 'S3 Event', type: 'event' },
    { from: 'SQS', to: 'Lambda', label: 'Poll Messages', type: 'data' },
    { from: 'Lambda', to: 'DynamoDB', label: 'Track Files', type: 'data' },
    { from: 'Lambda', to: 'Manifests', label: 'Create Batch', type: 'data' },
    { from: 'Manifests', to: 'Glue', label: 'Trigger', type: 'event' },
    { from: 'Glue', to: 'S3 Output', label: 'Write Parquet', type: 'data' },
    { from: 'Glue', to: 'EventBridge', label: 'State Change', type: 'event' },
    { from: 'EventBridge', to: 'Control Plane', label: 'Trigger', type: 'event' },
    { from: 'Control Plane', to: 'CloudWatch', label: 'Metrics', type: 'metric' },
    { from: 'Control Plane', to: 'SNS', label: 'Alerts', type: 'alert' }
  ];

  const stats = [
    { label: 'Throughput', value: '700 GB', unit: '/hour' },
    { label: 'Files', value: '200K', unit: '/hour' },
    { label: 'Latency', value: '2-5', unit: 'min' },
    { label: 'Cost', value: '~$15K', unit: '/month' }
  ];

  const ComponentCard = ({ id, data, x, y }) => (
    <g
      transform={`translate(${x}, ${y})`}
      onClick={() => setSelectedComponent(id)}
      style={{ cursor: 'pointer' }}
    >
      <rect
        width="140"
        height="80"
        rx="12"
        fill={selectedComponent === id ? data.color : '#1e2a3a'}
        stroke={data.color}
        strokeWidth="2"
        opacity={selectedComponent === id ? 1 : 0.9}
      />
      <text x="70" y="30" textAnchor="middle" fill="white" fontSize="24">
        {data.icon}
      </text>
      <text x="70" y="55" textAnchor="middle" fill="white" fontSize="11" fontWeight="600">
        {data.name}
      </text>
      <text x="70" y="70" textAnchor="middle" fill="#8892b0" fontSize="9">
        {data.type}
      </text>
    </g>
  );

  const Arrow = ({ x1, y1, x2, y2, label }) => {
    const midX = (x1 + x2) / 2;
    const midY = (y1 + y2) / 2;
    return (
      <g>
        <defs>
          <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
            <polygon points="0 0, 10 3.5, 0 7" fill="#00d4aa" />
          </marker>
        </defs>
        <line
          x1={x1}
          y1={y1}
          x2={x2}
          y2={y2}
          stroke="#00d4aa"
          strokeWidth="2"
          markerEnd="url(#arrowhead)"
          opacity="0.6"
        />
        {label && (
          <text x={midX} y={midY - 5} textAnchor="middle" fill="#8892b0" fontSize="8">
            {label}
          </text>
        )}
      </g>
    );
  };

  return (
    <div className="min-h-screen bg-gray-900 text-white p-6">
      <div className="max-w-7xl mx-auto">
        {/* Header */}
        <div className="text-center mb-8">
          <h1 className="text-3xl font-bold bg-gradient-to-r from-cyan-400 to-purple-500 bg-clip-text text-transparent">
            🏗️ NDJSON to Parquet Pipeline
          </h1>
          <p className="text-gray-500 mt-2">SQS + Manifest + Glue Streaming Architecture v1.1.0</p>
        </div>

        {/* Tabs */}
        <div className="flex justify-center gap-4 mb-8">
          {['architecture', 'dataflow', 'stats'].map((tab) => (
            <button
              key={tab}
              onClick={() => setActiveTab(tab)}
              className={`px-6 py-2 rounded-lg font-medium transition-all ${
                activeTab === tab
                  ? 'bg-cyan-500 text-white'
                  : 'bg-gray-800 text-gray-400 hover:bg-gray-700'
              }`}
            >
              {tab.charAt(0).toUpperCase() + tab.slice(1)}
            </button>
          ))}
        </div>

        {/* Architecture View */}
        {activeTab === 'architecture' && (
          <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div className="lg:col-span-2">
              <svg viewBox="0 0 800 500" className="w-full bg-gray-800 rounded-xl">
                {/* Layer Labels */}
                <text x="100" y="30" fill="#00d4aa" fontSize="12" fontWeight="bold">INGESTION</text>
                <text x="300" y="30" fill="#00d4aa" fontSize="12" fontWeight="bold">PROCESSING</text>
                <text x="520" y="30" fill="#00d4aa" fontSize="12" fontWeight="bold">STORAGE</text>
                <text x="680" y="30" fill="#00d4aa" fontSize="12" fontWeight="bold">MONITORING</text>

                {/* Components */}
                <ComponentCard id="s3Input" data={components.s3Input} x={30} y={50} />
                <ComponentCard id="sqs" data={components.sqs} x={30} y={150} />
                <ComponentCard id="lambda1" data={components.lambda1} x={230} y={100} />
                <ComponentCard id="glue" data={components.glue} x={230} y={220} />
                <ComponentCard id="dynamodb" data={components.dynamodb} x={430} y={100} />
                <ComponentCard id="s3Output" data={components.s3Output} x={430} y={220} />
                <ComponentCard id="controlPlane" data={components.controlPlane} x={630} y={100} />
                <ComponentCard id="cloudwatch" data={components.cloudwatch} x={630} y={220} />

                {/* Arrows */}
                <Arrow x1="100" y1="130" x2="100" y2="150" label="" />
                <Arrow x1="170" y1="190" x2="230" y2="140" label="poll" />
                <Arrow x1="370" y1="140" x2="430" y2="140" label="track" />
                <Arrow x1="300" y1="200" x2="300" y2="220" label="" />
                <Arrow x1="370" y1="260" x2="430" y2="260" label="write" />
                <Arrow x1="500" y1="200" x2="630" y2="140" label="state" />
                <Arrow x1="700" y1="180" x2="700" y2="220" label="metrics" />
              </svg>
            </div>

            {/* Details Panel */}
            <div className="bg-gray-800 rounded-xl p-6">
              <h3 className="text-lg font-semibold mb-4 text-cyan-400">
                {selectedComponent ? components[selectedComponent].name : 'Select a Component'}
              </h3>
              {selectedComponent && (
                <div className="space-y-4">
                  <div className="flex items-center gap-3">
                    <span className="text-3xl">{components[selectedComponent].icon}</span>
                    <span
                      className="px-3 py-1 rounded-full text-sm"
                      style={{ backgroundColor: components[selectedComponent].color + '33', color: components[selectedComponent].color }}
                    >
                      {components[selectedComponent].type}
                    </span>
                  </div>
                  <p className="text-gray-400 text-sm">{components[selectedComponent].details.purpose}</p>
                  <div>
                    <h4 className="text-sm font-medium text-gray-300 mb-2">Specifications</h4>
                    <ul className="space-y-1">
                      {components[selectedComponent].details.specs.map((spec, i) => (
                        <li key={i} className="text-sm text-gray-500 flex items-center gap-2">
                          <span className="w-1.5 h-1.5 bg-cyan-400 rounded-full"></span>
                          {spec}
                        </li>
                      ))}
                    </ul>
                  </div>
                  <div>
                    <h4 className="text-sm font-medium text-gray-300 mb-2">Configuration</h4>
                    <ul className="space-y-1">
                      {components[selectedComponent].details.config.map((cfg, i) => (
                        <li key={i} className="text-sm text-gray-500 flex items-center gap-2">
                          <span className="w-1.5 h-1.5 bg-purple-400 rounded-full"></span>
                          {cfg}
                        </li>
                      ))}
                    </ul>
                  </div>
                </div>
              )}
            </div>
          </div>
        )}

        {/* Data Flow View */}
        {activeTab === 'dataflow' && (
          <div className="bg-gray-800 rounded-xl p-6">
            <div className="space-y-4">
              {dataFlow.map((flow, i) => (
                <div key={i} className="flex items-center gap-4">
                  <div className="w-32 text-right text-sm font-medium">{flow.from}</div>
                  <div className="flex-1 flex items-center gap-2">
                    <div className="h-0.5 flex-1 bg-gradient-to-r from-cyan-500 to-purple-500"></div>
                    <span className="px-3 py-1 bg-gray-700 rounded-full text-xs">{flow.label}</span>
                    <div className="h-0.5 flex-1 bg-gradient-to-r from-purple-500 to-cyan-500"></div>
                    <span className="text-cyan-400">→</span>
                  </div>
                  <div className="w-32 text-sm font-medium">{flow.to}</div>
                  <span
                    className={`px-2 py-0.5 rounded text-xs ${
                      flow.type === 'data' ? 'bg-blue-900 text-blue-300' :
                      flow.type === 'event' ? 'bg-yellow-900 text-yellow-300' :
                      flow.type === 'metric' ? 'bg-green-900 text-green-300' :
                      'bg-red-900 text-red-300'
                    }`}
                  >
                    {flow.type}
                  </span>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Stats View */}
        {activeTab === 'stats' && (
          <div className="grid grid-cols-2 md:grid-cols-4 gap-6">
            {stats.map((stat, i) => (
              <div key={i} className="bg-gray-800 rounded-xl p-6 text-center">
                <div className="text-4xl font-bold bg-gradient-to-r from-cyan-400 to-purple-500 bg-clip-text text-transparent">
                  {stat.value}
                </div>
                <div className="text-gray-500 text-sm mt-1">
                  {stat.label}
                  <span className="text-gray-600">{stat.unit}</span>
                </div>
              </div>
            ))}
          </div>
        )}

        {/* Legend */}
        <div className="flex justify-center gap-6 mt-8 text-sm">
          {Object.entries({ storage: '#ff9f43', compute: '#ff6b6b', queue: '#00d4ff', database: '#26de81', monitoring: '#74b9ff' }).map(([type, color]) => (
            <div key={type} className="flex items-center gap-2">
              <div className="w-3 h-3 rounded" style={{ backgroundColor: color }}></div>
              <span className="text-gray-500 capitalize">{type}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

export default PipelineDiagram;

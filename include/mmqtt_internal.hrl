
-record(topic, {name}).

-record(trie, {edge, node_id}).
-record(trie_node, {node_id, edge_count=0, topic}).
-record(trie_edge, {node_id, word}).

-record(subscriber, {topic, qos, client}).
